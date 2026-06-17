.PHONY: build push

build:
	bash ./scripts/build-images.sh

push:
	bash ./scripts/push-images.sh
