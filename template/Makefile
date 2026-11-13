# Builds the app with pocketbook-kit: the kit/ submodule if there is one, else the pb
# command on your PATH. PB_KIT=/path/to/pocketbook-kit picks another checkout.
PB_KIT ?= kit
PB := $(if $(wildcard $(PB_KIT)/pb.sh),$(PB_KIT)/pb.sh,pb)

.PHONY: setup run pc arm test shell clean

# Fetch the kit (if it's a submodule), its SDK and the container image
setup:
	$(if $(wildcard .gitmodules),git submodule update --init --recursive)
	$(PB) setup

# Build for PC and open the app in the emulator
run:
	$(PB) run .

# Build for PC only
pc:
	$(PB) pc .

# Build for the device: copy build/<app>/<sdk>/arm/<app>.app to its applications/ folder
arm:
	$(PB) arm .

# Build and run the tests in tests/tests.pro
test:
	$(PB) test .

# Shell in the build container
shell:
	$(PB) shell .

clean:
	$(PB) clean .
