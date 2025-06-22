# init-downloader

Downloads a list of files from S3 compat. bucket to local disk. Useful when a containerized app needs certain data locally at startup.

## How to use

Set env. vars for S3 client
```
AWS_ENDPOINT_URL=https://minio.example.com
AWS_ACCESS_KEY_ID=REPLACE
AWS_SECRET_ACCESS_KEY=REPLACE
AWS_DEFAULT_REGION=us-west-1a
```

Use the env var `S3_COPY_LIST` to set a comma seprated list of s3 source files and local destination paths. E.g. `s3://bucket/file/path1:/local/path,s3://bucket/file/path2:/local/path`.

```
S3_COPY_LIST=s3://bikehopper-staging/shared/north-america/us/california/bay-area/gtfs.zip:/app/data
```