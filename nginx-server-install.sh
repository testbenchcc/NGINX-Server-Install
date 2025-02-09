#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Define domain
DOMAIN="husqy.net"
WEBROOT="/var/www/$DOMAIN/html"

echo "Updating package lists..."
sudo apt update -y

# Install and setup Tailscale
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo "Enabling and starting Tailscale service..."
sudo systemctl enable tailscaled
sudo systemctl start tailscaled

echo "Starting Tailscale with SSH enabled..."
sudo tailscale up --ssh

# Install Nginx
echo "Installing Nginx..."
sudo apt install -y nginx

# Opening ports in firewall
sudo ufw allow 80
sudo ufw allow 443

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
        sudo ufw allow 'Nginx Full'
        ;;
    2)
        echo "Applying 'Nginx HTTP' firewall rule..."
        sudo ufw allow 'Nginx HTTP'
        ;;
    3)
        echo "Applying 'Nginx HTTPS' firewall rule..."
        sudo ufw allow 'Nginx HTTPS'
        ;;
    4)
        echo "Skipping firewall adjustments..."
        ;;
    *)
        echo "Invalid choice! Defaulting to 'Nginx Full'."
        sudo ufw allow 'Nginx Full'
        ;;
esac

sudo ufw reload

# Verify firewall status (optional)
sudo ufw status

# Enable
yes | sudo ufw enable

# Enable Nginx on boot
echo "Enabling Nginx to start on boot..."
sudo systemctl enable nginx

# Start Nginx Now
echo "Starting Nginx..."
sudo systemctl start nginx

# Create Web Root and Set Permissions
echo "Setting up web root directory..."
sudo mkdir -p $WEBROOT
sudo chown -R $USER:$USER /var/www/$DOMAIN
sudo chmod -R 755 /var/www/$DOMAIN

sudo mkdir /var/www/$DOMAIN/certs
sudo nano /var/www/$DOMAIN/certs/origin.pem
sudo nano /var/www/$DOMAIN/certs/private.pem

# Create a sample index.html page
echo "Creating index.html..."
sudo tee "$WEBROOT/index.html" > /dev/null <<EOF
<html>
    <head>
        <title>Welcome to $DOMAIN!</title>
    </head>
    <body>
        <h1>Success! The $DOMAIN server block is working!</h1>
    </body>
</html>
EOF

# Create Nginx Server Block
echo "Configuring Nginx server block..."
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://$host$request_uri;  # Redirect all HTTP to HTTPS
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /var/www/$DOMAIN/certs/origin.pem;
    ssl_certificate_key /var/www/$DOMAIN/certs/private.pem;

    location / {
        proxy_pass http://zbook:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# Enable server block
echo "Enabling Nginx site configuration..."
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

# Search and replace: Uncomment 'server_names_hash_bucket_size 64;'
echo "Uncommenting 'server_names_hash_bucket_size 64;' in nginx.conf..."
sudo nano /etc/nginx/nginx.conf

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
