#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Get domain and service address from user
read -p "Enter your public domain (e.g., husqy.net): " DOMAIN
read -p "Enter your full service address (e.g., http://zbook:3000): " SERVICE_ADDRESS

# Validate inputs
if [ -z "$DOMAIN" ] || [ -z "$SERVICE_ADDRESS" ]; then
    echo "Error: Domain and service address cannot be empty"
    exit 1
fi

WEBROOT="/var/www/$DOMAIN/html"

# Function to handle SSL certificate
setup_ssl_certificate() {
    echo "Setting up SSL certificate..."
    echo "Choose SSL certificate option:"
    echo "1) Use existing certificate files"
    echo "2) Paste certificate data"
    echo "3) Generate new certificate with Certbot"
    read -p "Enter selection [1-3]: " SSL_CHOICE

    case "$SSL_CHOICE" in
        1)
            read -p "Enter path to SSL certificate file: " SSL_CERT
            read -p "Enter path to SSL private key file: " SSL_KEY
            if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
                echo "Error: Certificate files not found"
                exit 1
            fi
            # Copy certificate files to appropriate location
            sudo cp "$SSL_CERT" "/etc/ssl/certs/$DOMAIN.crt"
            sudo cp "$SSL_KEY" "/etc/ssl/private/$DOMAIN.key"
            ;;
        2)
            # Create temporary files for certificate data
            TEMP_CERT=$(mktemp)
            TEMP_KEY=$(mktemp)
            
            echo "Paste your certificate data (press Ctrl+D when done):"
            cat > "$TEMP_CERT"
            
            echo "Paste your private key data (press Ctrl+D when done):"
            cat > "$TEMP_KEY"
            
            # Validate certificate and key
            if ! openssl x509 -noout -in "$TEMP_CERT" 2>/dev/null; then
                echo "Error: Invalid certificate data"
                rm "$TEMP_CERT" "$TEMP_KEY"
                exit 1
            fi
            
            if ! openssl rsa -noout -in "$TEMP_KEY" 2>/dev/null; then
                echo "Error: Invalid private key data"
                rm "$TEMP_CERT" "$TEMP_KEY"
                exit 1
            fi
            
            # Copy validated files to appropriate location
            sudo mv "$TEMP_CERT" "/etc/ssl/certs/$DOMAIN.crt"
            sudo mv "$TEMP_KEY" "/etc/ssl/private/$DOMAIN.key"
            sudo chmod 644 "/etc/ssl/certs/$DOMAIN.crt"
            sudo chmod 600 "/etc/ssl/private/$DOMAIN.key"
            ;;
        3)
            echo "Installing Certbot..."
            sudo apt install -y certbot python3-certbot-nginx
            echo "Generating SSL certificate with Certbot..."
            sudo certbot --nginx -d "$DOMAIN"
            ;;
        *)
            echo "Invalid selection"
            exit 1
            ;;
    esac
}

# Function to create Nginx configuration
create_nginx_config() {
    echo "Creating Nginx configuration..."
    sudo tee /etc/nginx/sites-available/$DOMAIN << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/certs/$DOMAIN.crt;
    ssl_certificate_key /etc/ssl/private/$DOMAIN.key;

    location / {
        proxy_pass $SERVICE_ADDRESS;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
}

firewall_config() {
    local rule_name="${1:?firewall-config requires a rule name (Nginx Full, Nginx HTTP, Nginx HTTPS)}"
    sudo ufw allow "$rule_name"
    yes | sudo ufw enable
    sudo ufw commit
    sudo ufw reload
}

echo "Updating package lists..."
sudo apt update -y

# Ask about Tailscale installation
read -p "Would you like to install Tailscale? (y/n): " INSTALL_TAILSCALE
if [[ "$INSTALL_TAILSCALE" =~ ^[Yy]$ ]]; then
    # Install required packages
    echo "Installing required packages..."
    sudo apt install -y curl

    # Install and setup Tailscale
    echo "Installing Tailscale..."
    if ! curl -fsSL https://tailscale.com/install.sh | sudo sh; then
        echo "Failed to install Tailscale. Please check your internet connection and try again."
        exit 1
    fi

    echo "Enabling and starting Tailscale service..."
    if ! systemctl is-active --quiet tailscaled; then
        if ! sudo systemctl enable tailscaled; then
            echo "Failed to enable Tailscale service. Please check if Tailscale was installed correctly."
            exit 1
        fi
        if ! sudo systemctl start tailscaled; then
            echo "Failed to start Tailscale service. Please check if Tailscale was installed correctly."
            exit 1
        fi
    fi

    echo "Starting Tailscale with SSH enabled..."
    if ! sudo tailscale up --ssh; then
        echo "Failed to configure Tailscale. Please check if Tailscale was installed correctly."
        exit 1
    fi
fi

# Install Nginx
echo "Installing Nginx..."
sudo apt install -y nginx

# Prompt user to choose a firewall rule
echo "Choose a firewall rule to apply:"
echo "1) Nginx Full (Allows both HTTP & HTTPS)"
echo "2) Nginx HTTP (Allows only HTTP)"
echo "3) Nginx HTTPS (Allows only HTTPS)"
echo "4) Skip firewall setup"

read -p "Enter selection [1-4]: " FIREWALL_CHOICE

case "$FIREWALL_CHOICE" in
    1)
        echo "Applying 'Nginx Full' firewall rule..."
        firewall_config 'Nginx Full'
        ;;
    2)
        echo "Applying 'Nginx HTTP' firewall rule..."
        firewall_config 'Nginx HTTP'
        ;;
    3)
        echo "Applying 'Nginx HTTPS' firewall rule..."
        firewall_config 'Nginx HTTPS'
        ;;
    4)
        echo "Skipping firewall setup..."
        ;;
    *)
        echo "Invalid selection"
        exit 1
        ;;
esac

# Verify firewall status (optional)
sudo ufw status

# Create web root directory
sudo mkdir -p "$WEBROOT"
sudo chown -R $USER:$USER /var/www/$DOMAIN
sudo chmod -R 755 /var/www/$DOMAIN

setup_ssl_certificate
create_nginx_config

# Enable server block
echo "Enabling Nginx site configuration..."
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

# Enable Nginx on boot
echo "Enabling Nginx to start on boot..."
sudo systemctl enable nginx

# Test Nginx config and reload
echo "Testing Nginx configuration..."
if sudo nginx -t; then
    echo "Restarting Nginx..."
    sudo systemctl restart nginx
else
    echo "Nginx configuration test failed. Please check manually."
    exit 1
fi

# Display the public IP of the server
echo "Installation completed! Your server should now be accessible at:"
curl -4 icanhazip.com
echo ""
echo "Set your SSL/TLS setting to full on cloudflare. You will only see the server"
echo "block if you acces it with your domain name. If you visit the site with the "
echo "address above, you will see the standard NGINX welcome page."

echo "Installation complete!"
read -p "Would you like to reboot now? (y/n): " REBOOT_CHOICE
if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
    echo "Rebooting system..."
    sudo reboot
else
    echo "Please remember to reboot your system to apply all changes."
fi
