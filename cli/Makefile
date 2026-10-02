build:
	go build -o nrc ./cmd/nrc

USER_BIN_DIR ?= $(HOME)/.local/bin

run: build
	./nrc

test:
	go test ./...

clean:
	rm -f nrc

# Install the CLI for the current user
# Usage: make install-user [USER_BIN_DIR=~/.local/bin]
install-user: build
	mkdir -p $(USER_BIN_DIR)
	install -m 755 nrc $(USER_BIN_DIR)/nrc
	@echo "Installed CLI to $(USER_BIN_DIR)/nrc"

