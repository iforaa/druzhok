.PHONY: build run test clean

build:
	go build -o bin/druzhok ./cmd/druzhok

run:
	go run ./cmd/druzhok

test:
	go test ./internal/... -v

clean:
	rm -rf bin/ data/
