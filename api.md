# API Reference

zs3 implements a subset of the AWS S3 REST API with SigV4 authentication.

## Authentication

All requests must be signed using AWS Signature Version 4.

```
Authorization: AWS4-HMAC-SHA256
  Credential={access_key}/{date}/{region}/s3/aws4_request,
  SignedHeaders={signed_headers},
  Signature={signature}
```

Required headers:
- `Authorization` - SigV4 signature
- `x-amz-date` - Request timestamp (ISO 8601)
- `x-amz-content-sha256` - SHA256 hash of request body
- `Host` - Server hostname

## Bucket Operations

### ListBuckets

```
GET /
```

Returns XML list of all buckets.

### CreateBucket

```
PUT /{bucket}
```

Creates a new bucket. Bucket names must be 3-63 characters, alphanumeric, hyphens, and dots only.

### DeleteBucket

```
DELETE /{bucket}
```

Deletes an empty bucket. Returns 409 if bucket is not empty.

## Object Operations

### PutObject

```
PUT /{bucket}/{key}
```

Uploads an object. Creates parent directories as needed.

Response headers:
- `ETag` - MD5 hash of object content

### GetObject

```
GET /{bucket}/{key}
```

Downloads an object.

Supports range requests:
```
Range: bytes=0-1023
```

Response: 206 Partial Content with `Content-Range` header.

### HeadObject

```
HEAD /{bucket}/{key}
```

Returns object metadata without body.

Response headers:
- `Content-Length` - Object size in bytes

### DeleteObject

```
DELETE /{bucket}/{key}
```

Deletes an object. Returns 204 even if object doesn't exist.

### ListObjectsV2

```
GET /{bucket}?list-type=2
```

Query parameters:
- `prefix` - Filter by key prefix
- `delimiter` - Group keys by delimiter (typically `/`)
- `max-keys` - Maximum results (default 1000)
- `continuation-token` - Pagination token

Response: XML with `Contents` and `CommonPrefixes` elements.

## Multipart Upload

### InitiateMultipartUpload

```
POST /{bucket}/{key}?uploads
```

Returns XML with `UploadId`.

### UploadPart

```
PUT /{bucket}/{key}?uploadId={id}&partNumber={n}
```

Uploads a part. Part numbers start at 1.

Response headers:
- `ETag` - MD5 hash of part content

### CompleteMultipartUpload

```
POST /{bucket}/{key}?uploadId={id}
```

Assembles parts into final object. Request body contains part list (ignored - all parts are assembled in order).

### AbortMultipartUpload

```
DELETE /{bucket}/{key}?uploadId={id}
```

Cancels upload and deletes uploaded parts.

## Error Responses

All errors return XML:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>ErrorCode</Code>
  <Message>Human readable message</Message>
</Error>
```

| Code | Status | Description |
|------|--------|-------------|
| AccessDenied | 403 | Invalid credentials |
| InvalidBucketName | 400 | Bucket name validation failed |
| InvalidKey | 400 | Object key validation failed |
| NoSuchKey | 404 | Object not found |
| NoSuchBucket | 404 | Bucket not found |
| BucketNotEmpty | 409 | Cannot delete non-empty bucket |
| NoSuchUpload | 404 | Multipart upload not found |
| MethodNotAllowed | 405 | HTTP method not supported |
| InternalError | 500 | Server error |

## Limits

| Limit | Value |
|-------|-------|
| Max header size | 8 KB |
| Max body size | 5 GB |
| Max key length | 1024 bytes |
| Bucket name length | 3-63 characters |
