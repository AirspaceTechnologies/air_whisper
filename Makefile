.PHONY: all bootstrap build test app clean

# Both tests and app packaging use the same SwiftPM build and vendored framework.
.NOTPARALLEL:

all: test app

bootstrap:
	./scripts/bootstrap-whisper.sh

build: bootstrap
	./scripts/swift.sh build

test: bootstrap
	./scripts/swift.sh test

app:
	./scripts/build-app.sh

clean:
	rm -rf .build dist
