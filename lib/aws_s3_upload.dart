library aws_s3_upload;

import 'dart:io';

import 'package:amazon_cognito_identity_dart_2/sig_v4.dart';
import 'package:aws_s3_upload/enum/acl.dart';
import 'package:aws_s3_upload/src/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:recase/recase.dart';

import './src/policy.dart';

enum Domain {
  amazonaws,
  digitaloceanspaces;

  static Domain fromStr(String str) =>
      values.firstWhere((t) => t.name.contains(str));
}

/// Convenience class for uploading files to AWS S3
class AwsS3 {
  /// Upload a file, returning the file's public URL on success.
  static Future<String?> uploadFile({
    /// AWS access key
    required String accessKey,

    /// AWS secret key
    required String secretKey,

    /// The name of the S3 storage bucket to upload  to
    required String bucket,

    /// The file to upload
    required File file,

    /// The key to save this file as. Will override destDir and filename if set.
    String? key,

    /// The path to upload the file to (e.g. "uploads/public"). Defaults to the root "directory"
    String destDir = '',

    /// The AWS region. Must be formatted correctly, e.g. us-west-1
    String region = 'us-east-2',

    /// Access control list enables you to manage access to bucket and objects
    /// For more information visit [https://docs.aws.amazon.com/AmazonS3/latest/userguide/acl-overview.html]
    ACL acl = ACL.public_read,

    /// The filename to upload as. If null, defaults to the given file's current filename.
    String? filename,

    /// The content-type of file to upload. defaults to binary/octet-stream.
    String contentType = 'binary/octet-stream',

    /// If set to true, https is used instead of http. Default is true.
    bool useSSL = true,

    /// Additional metadata to be attached to the upload
    Map<String, String>? metadata,

    /// The domain to use for the endpoint. Defaults to `amazonaws`.
    String? domain,
  }) async {
    domain ??= Domain.amazonaws.name;
    final httpStr = 'http${useSSL ? 's' : ''}';
    final endpoint =
        '$httpStr://$bucket${Domain.fromStr(domain) == Domain.amazonaws ? '.s3' : ''}.$region.$domain.com';

    String? uploadKey;

    if (key != null) {
      uploadKey = key;
    } else if (destDir.isNotEmpty) {
      uploadKey = '$destDir/${filename ?? path.basename(file.path)}';
    } else {
      uploadKey = '${filename ?? path.basename(file.path)}';
    }

    final stream = http.ByteStream(Stream.castFrom(file.openRead()));
    final length = await file.length();

    final uri = Uri.parse(endpoint);
    final req = http.MultipartRequest("POST", uri);
    final multipartFile = http.MultipartFile(
      'file',
      stream,
      length,
      filename: path.basename(file.path),
    );

    // Convert metadata to AWS-compliant params before generating the policy.
    final metadataParams = _convertMetadataToParams(metadata);

    // Generate pre-signed policy.
    final policy = Policy.fromS3PresignedPost(
      uploadKey,
      bucket,
      accessKey,
      15,
      length,
      acl,
      region: region,
      metadata: metadataParams,
    );

    final signingKey = SigV4.calculateSigningKey(
      secretKey,
      policy.datetime,
      region,
      's3',
    );
    final signature = SigV4.calculateSignature(signingKey, policy.encode());

    req.files.add(multipartFile);
    req.fields['key'] = policy.key;
    req.fields['acl'] = aclToString(acl);
    req.fields['X-Amz-Credential'] = policy.credential;
    req.fields['X-Amz-Algorithm'] = 'AWS4-HMAC-SHA256';
    req.fields['X-Amz-Date'] = policy.datetime;
    req.fields['Policy'] = policy.encode();
    req.fields['X-Amz-Signature'] = signature;
    req.fields['Content-Type'] = contentType;

    // If metadata isn't null, add metadata params to the request.
    if (metadata != null) {
      req.fields.addAll(metadataParams);
    }

    try {
      final res = await req.send();

      if (res.statusCode == 204) return '$endpoint/$uploadKey';
    } catch (e) {
      debugPrint('Failed to upload to AWS, with exception:');
      debugPrint(e.toString());
      return null;
    }
    return null;
  }

  /// A method to transform the map keys into the format compliant with AWS.
  /// AWS requires that each metadata param be sent as `x-amz-meta-*`.
  static Map<String, String> _convertMetadataToParams(
    Map<String, String>? metadata,
  ) {
    Map<String, String> updatedMetadata = {};

    if (metadata != null) {
      for (var k in metadata.keys) {
        updatedMetadata['x-amz-meta-${k.paramCase}'] = metadata[k]!;
      }
    }

    return updatedMetadata;
  }
}
