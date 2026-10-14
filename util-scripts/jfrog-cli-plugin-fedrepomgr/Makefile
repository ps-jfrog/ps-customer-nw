ifneq (,$(wildcard ./.env))
    include .env
    export
endif

prep:
	mkdir -p test/$(PLUGIN_NAME)/$(VERSION)/{linux-amd64,mac-386}

build_lnx:
	env GOOS=linux GOARCH=amd64 go build -o test/$(PLUGIN_NAME)/$(VERSION)/linux-amd64/$(PLUGIN_NAME)

build_mac:
	env GOOS=darwin GOARCH=amd64 go build -o test/$(PLUGIN_NAME)/$(VERSION)/mac-386/$(PLUGIN_NAME)

build: build_mac build_lnx 

# t_create_lnx:
# 	./test/$(PLUGIN_NAME)/$(VERSION)/linux-amd64/$(PLUGIN_NAME) $(ACTION) $(REPO_TYPE) $(SRC_RT)  $(TGT_RT) --dry-run=$(DRY_RUN) --inventory=$(INVENTORY)

clean: 
	rm -rf test/$(PLUGIN_NAME)

all: clean build test

test: t_add_fed

t_help:
	./test/$(PLUGIN_NAME)/$(VERSION)/mac-386/$(PLUGIN_NAME)  -h

t_convert:
	./test/$(PLUGIN_NAME)/$(VERSION)/mac-386/$(PLUGIN_NAME) convert $(SRC_RT) --dry-run=true --include-repo="lyon-conan-dev-local;lyon-generic-dev-local;lyon-go-dev-local;lyon-nuget-dev-local;lyon-rpm-dev-local;"

# ./test/$(PLUGIN_NAME)/$(VERSION)/mac-386/$(PLUGIN_NAME) convert $(SRC_RT) --include-repo="lyon-rpm-dev-local"
# --dry-run=true

t_add_fed:
	./test/$(PLUGIN_NAME)/$(VERSION)/mac-386/$(PLUGIN_NAME) add-federation $(SRC_RT) $(DST_URLS) --include-repo="lyon-conan-dev-local;lyon-generic-dev-local;lyon-go-dev-local;lyon-nuget-dev-local;lyon-rpm-dev-local;" --dry-run=false
	
#./test/$(PLUGIN_NAME)/$(VERSION)/mac-386/$(PLUGIN_NAME) add-federation $(SRC_RT) $(DST_URLS) --include-repo="lyon-rpm-dev-local" --dry-run=false


# sunrise-staging-generic-local;sunrise-staging-maven-local;
#--include-repo="moonrise-staging-generic-local"
	
# --include-repo="*yucaipa*;*yann*" --exclude-repo="*yann*;*toto*"
