DART ?= dart

all: test

setup:
	$(DART) pub get

test:
	$(DART) test

lint:
	$(DART) analyze

generate:
	$(DART) run bin/generate.dart

clean:
	rm -rf .dart_tool/ build/ particle_top.sv
