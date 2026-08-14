# Intentionally undefaulted. build-images.sh defaults to linux/amd64 on its own,
# while push-images.sh requires an explicit value: defaulting here would make
# `make build-arm64 && make push-s3` publish arm64 images under the amd64 prefix.

.PHONY: build build-amd64 build-arm64 push push-s3 push-gcs

build:
	TARGET_PLATFORM="$(TARGET_PLATFORM)" bash ./scripts/build-images.sh

build-amd64:
	TARGET_PLATFORM=linux/amd64 bash ./scripts/build-images.sh

build-arm64:
	TARGET_PLATFORM=linux/arm64 bash ./scripts/build-images.sh

# TARGET_PLATFORM selects the <arch>/ key prefix images are published under, so
# it must match the platform they were built for.
push:
	TARGET_PLATFORM="$(TARGET_PLATFORM)" bash ./scripts/push-images.sh

push-s3:
	TARGET_PLATFORM="$(TARGET_PLATFORM)" S3_IMAGES_BUCKET="$(S3_IMAGES_BUCKET)" bash ./scripts/push-images.sh s3

push-gcs:
	TARGET_PLATFORM="$(TARGET_PLATFORM)" GCS_IMAGES_BUCKET="$(GCS_IMAGES_BUCKET)" bash ./scripts/push-images.sh gcs
