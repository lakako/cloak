export hostname := $(shell hostname)

.PHONY: iex
iex:
	iex --name cloak@${hostname}.local -S mix

.PHONY: docker
docker:
	docker build -t cloak .

.PHONY: release
release:
	MIX_ENV=prod mix release
