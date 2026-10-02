#!/bin/bash

# Generate self-signed certificates for development
# This is required for WebAuthn to work

echo "Generating self-signed SSL certificates for development..."

# Generate private key
openssl genrsa -out key.pem 2048

# Generate certificate
openssl req -new -x509 -key key.pem -out cert.pem -days 365 -subj "/C=US/ST=Local/L=Local/O=Orion Dev/CN=localhost"

echo "SSL certificates generated successfully!"
echo "Files created:"
echo "- key.pem (private key)"
echo "- cert.pem (certificate)"
echo ""
echo "Note: These are self-signed certificates for development only."
echo "Your browser will show a security warning - you can safely accept it for localhost."
