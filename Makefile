.PHONY: all bootstrap build test test-bootstrap app clean

# Both tests and app packaging use the same SwiftPM build and vendored framework.
.NOTPARALLEL:

all: test app

bootstrap:
	./scripts/bootstrap-whisper.sh
	./scripts/bootstrap-llama.sh

build: bootstrap
	./scripts/swift.sh build

test-bootstrap:
	./scripts/test-bootstrap-whisper.sh

test: test-bootstrap bootstrap
	./scripts/swift.sh test

app:
	./scripts/build-app.sh

clean:
	rm -rf .build dist
