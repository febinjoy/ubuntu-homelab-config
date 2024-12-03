#!/bin/bash

#------------------------------------------------ Config -----------------------------------------------
# Declare the timezone variable
timezone="Australia/Melbourne"

#--------------------------------------------- End of Config -------------------------------------------


# Global variables with default values
nginx_installed=0
iptables_installed=0
nginx_hostname="myserver.home"
nginx_hostname_domain="${nginx_hostname%%.*}"
server_ip="127.0.0.1"  # Replace with your actual IP address if needed
cockpit_installed=0

#------------------------------------------- Utility functions -----------------------------------------

# Function to prompt the user
prompt_user() {
    local question="$1"
    echo -n -e "\n--------------------------------------------------------------------------------------\n"
    echo -n "$question (Y/n): "
    read -r response
    response=$(echo "$response" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
    case "$response" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# Function to confirm reopening the file
confirm_reopen() {
    echo -n -e "\n--------------------------------------------------------------------------------------\n"
    read -r -p "Do you want to reopen the file for editing? reply (yes/y/Y) to reopen. Any other key to continue: " answer
    answer=$(echo "$answer" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
    if [[ "$answer" != "yes" && "$answer" != "y" && "$answer" != "Y" ]]; then
        return 1 # Indicate that the user does not want to reopen the file
    fi
    return 0 # Indicate that the user wants to reopen the file
}

# Function to open a file with nano
edit_file() {
    local file_path=$1

    while true; do
        sudo nano "$file_path"

        # Check if the user wants to reopen the file
        if ! confirm_reopen; then
            break # Exit the loop if the user does not want to reopen the file
        fi
    done
}

# Generic function to install packages with conditional pre and post install methods
install_packages() {
    local packages=("$@") # Convert the argument list to an array

    for package in "${packages[@]}"; do
        if prompt_user "Do you want to install $package?"; then
            local func_name="${package//[-.]/_}" # Replace hyphens and dots with underscores for function names
            # Check and run pre-install function if it exists
            if declare -f "pre_install_$func_name" > /dev/null; then
                echo "Running pre-install steps for $package..."
                "pre_install_$func_name"
            fi
            echo "Installing $package..."
            sudo apt update && sudo apt install -y "$package"
            # Check and run post-install function if it exists
            if declare -f "post_install_$func_name" > /dev/null; then
                echo "Running post-install steps for $package..."
                "post_install_$func_name"
            fi
        else
            echo "Skipping installation of $package."
        fi
    done
}

#--------------------------------------- End of Utility functions --------------------------------------

#------------------------------------------ Install functions ------------------------------------------


# Function to perform update
update() {
    echo "Updating the system..."
    sudo apt update -y
}

# Function to perform upgrade
upgrade() {
    echo "Upgrading the system..."
    sudo apt upgrade -y
}

# Function to configure Git
configure_git() {
    echo "Configuring git..."
    read -r -p "Enter your Name: " git_name
    read -r -p "Enter your Email: " git_email

    git_name=$(echo "$git_name" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
    git_email=$(echo "$git_email" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    git config --global user.name "$git_name"
    git config --global user.email "$git_email"

    echo "Git has been configured with the following details:"
    echo "Username: $git_name"
    echo "Email: $git_email"
}

# Function to generate SSH key and add it to the SSH agent
setup_ssh() {
    echo "Configuring SSH..."

    sudo apt install -y openssh-server

    read -r -p "Enter the email for SSH key: " ssh_email

    ssh_email=$(echo "$ssh_email" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    ssh-keygen -t ed25519 -C "$ssh_email"

    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519

    echo "SSH key generated and added to SSH agent."

    echo "Here is your public key:"
    cat ~/.ssh/id_ed25519.pub

    echo "Please add this public key to your GitHub account."
    read -r -p "Press enter to continue after adding the key to GitHub."
}

# Function to install LazyGit
install_lazygit() {
    if prompt_user "Do you want to install Lazygit?"; then

        echo "Installing LazyGit..."
        local LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | \grep -Po '"tag_name": *"v\K[^"]*')
        sudo curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
        tar xf lazygit.tar.gz lazygit
        sudo install lazygit -D -t /usr/local/bin/
    else
        echo "Skipping installation of Lazygit."
    fi
}

# Function to setup NTP
setup_ntp() {
    echo "Setting up NTP..."
    systemctl status systemd-timesyncd

    echo "Starting the service"
    sudo systemctl start systemd-timesyncd
    echo "Enabling the service"
    sudo systemctl enable systemd-timesyncd
    echo "timedatectl status:"
    timedatectl status

    echo "Opening timesyncd.conf. Set your NTP servers."
    read -r -p "Press enter to continue."
    edit_file /etc/systemd/timesyncd.conf

    echo "Restarting service..."
    sudo systemctl restart systemd-timesyncd

    echo "Setting Timezone..."
    sudo timedatectl set-timezone $timezone
    echo "The timezone has been set to $(timedatectl | grep 'Time zone')."
}

# Function to harden security
setup_sshd() {
    if prompt_user "Do you want to configure sshd?"; then

        echo "Hardening security by setting values in sshd_config..."
        echo "Please change the following values: "
        echo "Port <ssl_port> # Do not use default port (22)"
        echo "PermitRootLogin no"
        echo "MaxAuthTries 4"
        echo "PasswordAuthentication no"
        echo "PermitEmptyPasswords no"
        echo "PubkeyAuthentication yes"
        echo "AllowUsers <list of users>"
        read -r -p "Press enter to continue."

        edit_file /etc/ssh/sshd_config

        echo "Restarting SSH..."
        sudo systemctl restart ssh

        echo "Verifying..."
        read -r -p "Please enter SSH port number for testing: " port_number
        port_number=$(echo "$port_number" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
        sudo netstat -tuln | grep "$port_number"
    else
        echo "Skipping sshd configuration."
    fi
}

# Function to setup firewall
setup_firewall(){
    if prompt_user "Do you want to setup firewall?"; then
        export iptables_installed=1
        echo "Setting up firewall rules..."
        # Set Default Policies
        echo "Setting up default policies..."
        sudo iptables -P INPUT DROP
        sudo iptables -P FORWARD DROP
        sudo iptables -P OUTPUT ACCEPT

        # Allow SSH Connections
        read -r -p "Enter the port number you want to allow SSH comms through the firewall: " port_number
        port_number=$(echo "$port_number" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
        sudo iptables -A INPUT -p tcp --dport "$port_number" -j ACCEPT
        echo "Port $port_number has been allowed through the firewall."

        # Limit SSH Connection Rate (Anti-Brute-Force)
        echo "Limiting SSH Connection Rate (Anti-Brute-Force)..."
        sudo iptables -A INPUT -p tcp --dport "$port_number" -m conntrack --ctstate NEW -m recent --set
        sudo iptables -A INPUT -p tcp --dport "$port_number" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

        # Allow HTTP and HTTPS Traffic
        echo "Allowing HTTP and HTTPS traffic..."
        sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT

        # Allow Loop back traffic
        echo "Allowing Loop back traffic..."
        sudo iptables -A INPUT -i lo -j ACCEPT
        sudo iptables -A OUTPUT -o lo -j ACCEPT

        # Allow Established and Related Connections
        echo "Allowing Established and Related Connections..."
        sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        save_firewall_rules
        configure_iptables_service
    else
        echo "Skipping firewall configuration."
    fi

}

# Function to save firewall rules
save_firewall_rules(){
    local dirpath="/etc/iptables"
    local filepath="$dirpath/rules.v4"

    # Check if the directory exists
    if [[ ! -d "$dirpath" ]]; then
        echo "Directory $dirpath does not exist. Creating directory..."
        sudo mkdir -p "$dirpath"
        sudo chown root:root "$dirpath"
        sudo chmod 755 "$dirpath"
    fi

    # Check if the file exists
    if [[ -f "$filepath" ]]; then
        echo "File $filepath already exists. Saving iptables rules to the file."
    else
        echo "File $filepath does not exist. Creating and saving iptables rules to the file."
        sudo touch "$filepath"
    fi

    # Save iptables rules to the file
    sudo iptables-save | sudo tee "$filepath"
}

# Function to configure iptables service
configure_iptables_service() {
    echo "Writing to /etc/systemd/system/iptables.service..."

    sudo tee /etc/systemd/system/iptables.service > /dev/null <<EOL
[Unit]
Description=Packet Filtering Framework
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
ExecReload=/sbin/iptables-restore /etc/iptables/rules.v4
ExecStop=/sbin/iptables -F
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

    echo "Enabling iptables service..."
    sudo systemctl enable iptables

    echo "Restarting iptables and SSH services..."
    sudo systemctl restart iptables
    sudo systemctl restart ssh

    echo "iptables service configured and services restarted successfully."
}

# Function to install Cockpit
install_configure_cockpit() {
    if prompt_user "Do you want to install and configure cockpit?"; then

        echo "Updating and installing Cockpit and essential plugins..."
        sudo apt update
        sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils cockpit cockpit-sosreport cockpit-machines virt-manager --fix-missing

        echo "Enabling and starting Cockpit service..."
        sudo systemctl enable --now cockpit.socket

        # Check if nginx is installed and add config
        if [[ $nginx_installed -eq 1 ]]; then
            echo "Adding nginx proxy settings for Cockpit..."
            append_nginx_conf 9090 cockpit https
        fi

        if [[ $iptables_installed -eq 1 ]]; then
            echo "Adding firewall rules to allow Cockpit (HTTPS on port 9090)..."
            sudo iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
            save_firewall_rules
            echo "Firewall rules have been added to allow Cockpit."
        fi

        export cockpit_installed=1

        echo "Cockpit has been installed and configured successfully."

        echo "Cockpit is now available using https://<server-ip>:9090 from any machine in your network. Login with your server username and password."
    else
        echo "Skipping Cockpit install and configuration."
    fi
}

# Function to append a line to a file if it is not already there
append_line_to_file() {
    local file="$1"
    local line="$2"

    # Check if the file exists, create it if it doesn't
    if [[ ! -f "$file" ]]; then
        echo "File $file does not exist. Creating file..."
        sudo mkdir -p "$(dirname "$file")"
        sudo touch "$file"
    fi

    # Append the line to the file if it doesn't already exist in the file
    if ! grep -Fxq "$line" "$file"; then
        echo "$line" >> "$file"
        echo "$line appended to $file."
    else
        echo "$line already exists in $file."
    fi
}

# Function to get nginx host details
get_nginx_host_details(){
    read -r -p "Please enter the nginx hostname (default: $nginx_hostname): " nginxhostname

    nginxhostname=$(echo "$nginxhostname" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    # If the user input is not empty, update the variables; otherwise, use default
    if [[ -n "$nginxhostname" ]]; then
        export nginx_hostname="$nginxhostname"
        export nginx_hostname_domain="${nginxhostname%%.*}"
    fi

    # Print the updated variables
    echo "Full DNS hostname: $nginx_hostname"
    echo "First part of the DNS hostname: $nginx_hostname_domain"
}

# Function to append to nginx configuration
append_nginx_conf() {
    local port_number="$1"
    local package_name="$2"
    local protocol="${3:-http}" # Default to 'http' if no protocol is provided
    local conf_file_path="/etc/nginx/conf.d/$nginx_hostname_domain.conf"

    # Prompt for subdomain
    read -r -p "Please enter the subdomain (e.g., $package_name): " subdomain

    subdomain=$(echo "$subdomain" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    # Check if nginx_hostname is set; if not, prompt for it
    if [ -z "$nginx_hostname" ]; then
        read -r -p "Please enter the base DNS hostname (e.g., myserver.home): " nginx_hostname
        nginx_hostname=$(echo "$nginx_hostname" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
    fi

    # Form the full server_name
    local server_name="$subdomain.$nginx_hostname"

    # Configuration content with a line break at the start
    local conf_content="

server {
    listen 80;
    server_name $server_name;

    location / {
        proxy_pass http://$server_ip:$port_number;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}"

    # Append the configuration to the specified file
    echo "$conf_content" | sudo tee -a "$conf_file_path"

    echo "Configuration appended to $conf_file_path"

    echo "Testing Nginx config..."

    # Test Nginx config
    test_nginx_config

    # Restart Nginx
    echo "Restarting Nginx..."
    sudo systemctl restart nginx
}

# Function to test Nginx config
test_nginx_config() {
    echo "Testing Nginx config..."
    sudo nginx -t
    echo "Nginx config tested successfully."

    read -r -p "Do you want to manually edit the configuration? (yes/no)?" answer
    answer=$(echo "$answer" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    if [[ "$answer" == "yes" ]]; then
        echo "Opening Nginx configuration file for editing..."
        edit_file "/etc/nginx/conf.d/$nginx_hostname_domain.conf"
    fi

    read -r -p "Do you want to retest the Nginx? (yes/no)?" answer
    answer=$(echo "$answer" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    if [[ "$answer" == "yes" ]]; then
        test_nginx_config
    fi
}

# Function to download file and save it to the specified path
download_file() {
    local url="$1"
    local dest_path="$2"

    # Create the destination directory if it doesn't exist
    sudo mkdir -p "$(dirname "$dest_path")"

    # Download the file
    sudo wget "$url" -O "$dest_path"

    # Confirm the file was saved
    if [[ -f "$dest_path" ]]; then
        echo "File saved to $dest_path"
    else
        echo "Failed to save the file to $dest_path"
    fi
}

append_git_delta_to_gitconfig() {
    local gitconfig_path="$HOME/.gitconfig"

    # Create the .gitconfig file if it doesn't exist
    sudo touch "$gitconfig_path"

    # Append the configuration
    sudo cat <<EOL >> "$gitconfig_path"

[core]
    pager = delta

[interactive]
    diffFilter = delta --color-only

[include]
    # If you saved the config with a different name, use it
    path = ~/.config/delta/themes.gitconfig

[delta]
    features = arctic-fox
    navigate = true    # use n and N to move between diff sections
    line-numbers = true
    side-by-side = true

    # delta detects terminal colors automatically; set one of these to disable auto-detection
    # dark = true
    # light = true

[merge]
    conflictstyle = zdiff3
EOL

    echo "Configuration appended to $gitconfig_path"
}

# Function to restart the server
restart_server() {
    if prompt_user "Do you want to restart the server?"; then
        echo "Restarting the server..."
        sudo reboot
    fi
}

#       --------- Containers ----------

# Function to setup Containers
setup_containers(){
    if prompt_user "Do you want to install and configure containers?"; then
        install_configure_podman
        update_registries_conf
        setup_container_startup
        container_jellyfin
        create_postgresql_pod
        container_node_red
        container_homarr
        container_freshrss
    else
        echo "Skipping install and configuration of containers."
    fi
}

# Function to install and configure Podman
install_configure_podman() {
    echo "Updating package list..."
    sudo apt update

    echo "Installing Podman and Podman Remote..."
    sudo apt install -y podman podman-remote

    echo "Podman is installed and configured successfully."

    if [[ $iptables_installed -eq 1 ]]; then
        echo "Installing Cockpit Podman Plugin..."
        sudo apt install -y cockpit-podman

        echo "Enabling and starting Cockpit service..."
        sudo systemctl enable --now cockpit.socket

        echo "Cockpit Podman Plugin is installed and configured successfully."
    fi
}

# Function to update podman registries
update_registries_conf() {
    local file="/etc/containers/registries.conf"
    local search_section="[registries.search]"
    local registries="registries=['docker.io', 'quay.io']"

    # Check if the file exists
    if [[ ! -f "$file" ]]; then
        echo "File $file does not exist. Creating file..."
        sudo touch "$file"
    fi

    # Add the search section and registries
    if ! grep -Fxq "$search_section" "$file"; then
        echo "Adding $search_section to $file"
        echo -e "\n$search_section\n$registries" | sudo tee -a "$file"
    else
        # If the section exists, update the registries line
        echo "Updating $file with default search registries"
        sudo sed -i "/$search_section/!b;n;c$registries" "$file"
    fi

    echo "Default search registries have been added to $file."
}

# Function to set up and configure automatic container startup
setup_container_startup() {
    local username=$USER  # Get the current username

    echo "Creating the directory for containers..."
    # This is where all the container volumes are created
    sudo mkdir -p ~/.config/containers

    # This script will be executed on startup
    # Individual containers will add their start command to this file
    echo "Creating the start.sh script..."
    sudo tee ~/.config/containers/start.sh > /dev/null <<EOL
#!/bin/bash
EOL

    echo "Making the start.sh script executable..."
    sudo chmod +x ~/.config/containers/start.sh

    echo "Creating the systemd service file..."
    sudo tee /etc/systemd/system/start-containers.service > /dev/null <<EOL
[Unit]
Description=Start Podman Containers
After=network.target

[Service]
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="PATH=$PATH:/usr/local/bin:/usr/bin:/bin"
ExecStartPre=/bin/sleep 10
Type=simple
ExecStart=/bin/bash /home/$username/.config/containers/start.sh
Restart=always
User=$username

[Install]
WantedBy=default.target
EOL

    echo "Enabling the start-containers.service..."
    sudo systemctl enable start-containers.service

    echo "Starting the start-containers.service..."
    sudo systemctl start start-containers.service

    echo "Container startup setup is complete."
}

container_jellyfin(){
    local package_name="jellyfin"

    if prompt_user "Do you want to install container for $package_name?"; then
        echo "Installing $package_name..."
        sudo mkdir -p ~/.config/containers/$package_name/config
        sudo mkdir -p ~/.config/containers/$package_name/cache
        sudo mkdir -p ~/data/media

        sudo chmod -R 755 ~/.config/containers/$package_name ~/data/media

        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/config" --opt type=none --opt o=bind "$package_name-config"
        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/cache" --opt type=none --opt o=bind "$package_name-cache"
        sudo podman volume create --opt device="$HOME/data/media" --opt type=none --opt o=bind "$package_name-media"

        sudo podman run -d \
        --name $package_name \
        --restart=always \
        -p 8096:8096 \
        -p 8920:8920 \
        -v $package_name-config:/config \
        -v $package_name-cache:/cache \
        -v $package_name-media:/media \
        jellyfin/jellyfin:latest

    	if [[ $iptables_installed -eq 1 ]]; then
            echo "Creating firewall rules for $package_name..."
            sudo iptables -A INPUT -p tcp --dport 8096 -j ACCEPT
            sudo iptables -A INPUT -p tcp --dport 8920 -j ACCEPT
            save_firewall_rules
            echo "Firewall rules have been added to allow $package_name."
        fi

        append_line_to_file "$HOME/.config/containers/start.sh" "podman start $package_name"

        # Check if nginx is installed and add config
        if [[ $nginx_installed -eq 1 ]]; then
            echo "Adding nginx proxy settings for $package_name..."
            append_nginx_conf 8096 $package_name
        fi

        echo "Completed installing $package_name..."
    else
        echo "Skipping install and configuration of $package_name."
    fi
}

# Method to create PostgreSQL pod
create_postgresql_pod() {
    if prompt_user "Do you want to install and configure Postgres and pgAdmin?"; then
        echo "Creating PostgreSQL Pod..."
        sudo podman pod create --name postgre-sql -p 9876:80

        container_postgres
        container_pgadmin

        if [[ $iptables_installed -eq 1 ]]; then
            echo "Creating firewall rules for $package_name..."
            sudo iptables -A INPUT -p tcp --dport 9876 -j ACCEPT
            save_firewall_rules
            echo "Firewall rules have been added to allow $package_name."
        fi

        append_line_to_file "$HOME/.config/containers/start.sh" "podman pod start postgre-sql"

        # Check if nginx is installed and add config
        if [[ $nginx_installed -eq 1 ]]; then
            echo "Adding nginx proxy settings for $package_name..."
            append_nginx_conf 9876 $package_name
        fi
    else
        echo "Skipping install and configuration of Postgres and pgAdmin."
    fi

}

# Method to install Postgres DB
container_postgres() {
    local package_name="postgres"

    echo "Installing $package_name..."
    read -r -p "Please enter username for $package_name (e.g. admin): " user_name
    read -r -p "Please enter password for $package_name : " password

    user_name=$(echo "$user_name" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
    password=$(echo "$password" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    sudo mkdir -p ~/.config/containers/$package_name

    sudo chmod -R 755 ~/.config/containers/$package_name

    sudo podman volume create --opt device="$HOME/.config/containers/$package_name" --opt type=none --opt o=bind "$package_name-volume"

    sudo podman run -d \
    --name $package_name \
    --pod postgre-sql \
    -d -e POSTGRES_USER="$username" \
    -e POSTGRES_PASSWORD="$password" \
    -v $package_name-volume:/var/lib/postgresql/data:rw,z \
    docker.io/library/postgres:latest

    echo "Completed installing $package_name..."
}

# Method to install pgAdmin
container_pgadmin() {
    local package_name="pgadmin"

    echo "Installing $package_name..."
    read -r -p "Please enter email (username) for $package_name (e.g. youradmin@yourdomain.com): " user_name
    read -r -p "Please enter password for $package_name : " password

    user_name=$(echo "$user_name" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace
    password=$(echo "$password" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim leading and trailing whitespace

    sudo mkdir -p ~/.config/containers/$package_name

    sudo chmod -R 755 ~/.config/containers/$package_name

    sudo podman volume create --opt device="$HOME/.config/containers/$package_name" --opt type=none --opt o=bind "$package_name-volume"

    sudo podman run -d \
    --name $package_name \
    --pod postgre-sql \
    -e "PGADMIN_DEFAULT_EMAIL=$user_name" \
    -e "PGADMIN_DEFAULT_PASSWORD=$password" \
    -v $package_name-volume:/var/lib/pgadmin \
    -d docker.io/dpage/pgadmin4:latest

    echo "Completed installing $package_name..."
}

# Method to install Node-RED
container_node_red() {
    local package_name="nodered"

    if prompt_user "Do you want to install container for $package_name?"; then
        echo "Installing $package_name..."
        sudo mkdir -p ~/.config/containers/$package_name

        sudo chmod -R 755 ~/.config/containers/$package_name

        sudo podman volume create --opt device="$HOME/.config/containers/$package_name" --opt type=none --opt o=bind "$package_name-data"

        sudo podman run -d \
        --name $package_name \
        --restart=always \
        -p 1880:1880 \
        -v $package_name-data:/data \
        docker.io/nodered/node-red:latest

        if [[ $iptables_installed -eq 1 ]]; then
            echo "Creating firewall rules for $package_name..."
            sudo iptables -A INPUT -p tcp --dport 1880 -j ACCEPT
            save_firewall_rules
            echo "Firewall rules have been added to allow $package_name."
        fi

        append_line_to_file "$HOME/.config/containers/start.sh" "podman start $package_name"

        # Check if nginx is installed and add config
        if [[ $nginx_installed -eq 1 ]]; then
            echo "Adding nginx proxy settings for $package_name..."
            append_nginx_conf 1880 $package_name
        fi

        echo "Completed installing $package_name..."
    else
        echo "Skipping install and configuration of $package_name."
    fi

}

# Method to install Homarr
container_homarr() {
    local package_name="homarr"

    if prompt_user "Do you want to install container for $package_name?"; then
        echo "Installing $package_name..."
        sudo mkdir -p ~/.config/containers/$package_name/configs
        sudo mkdir -p ~/.config/containers/$package_name/icons
        sudo mkdir -p ~/.config/containers/$package_name/data

        sudo chmod -R 755 ~/.config/containers/$package_name

        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/configs" --opt type=none --opt o=bind "$package_name-configs"
        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/icons" --opt type=none --opt o=bind "$package_name-icons"
        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/data" --opt type=none --opt o=bind "$package_name-data"

        sudo podman run -d \
        -p 7575:7575 \
        --name $package_name \
        -v $package_name-configs:/app/data/configs \
        -v $package_name-icons:/app/public/icons \
        -v $package_name-data:/data \
        --restart unless-stopped \
        -e DEFAULT_COLOR_SCHEME=dark \
        ghcr.io/ajnart/homarr:latest

        if [[ $iptables_installed -eq 1 ]]; then
            echo "Creating firewall rules for $package_name..."
            sudo iptables -A INPUT -p tcp --dport 7575 -j ACCEPT
            save_firewall_rules
            echo "Firewall rules have been added to allow $package_name."
        fi

        append_line_to_file "$HOME/.config/containers/start.sh" "podman start $package_name"

        # Check if nginx is installed and add config
        if [[ $nginx_installed -eq 1 ]]; then
            echo "Adding nginx proxy settings for $package_name..."
            append_nginx_conf 7575 $package_name
        fi

        echo "Completed installing $package_name..."
    else
        echo "Skipping install and configuration of $package_name."
    fi
}

# Method to install FreshRSS
container_freshrss() {
    local package_name="freshrss"

    if prompt_user "Do you want to install container for $package_name?"; then
        echo "Installing $package_name..."
        sudo mkdir -p ~/.config/containers/$package_name/{data,extensions}

        sudo chmod -R 755 ~/.config/containers/$package_name

        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/data" --opt type=none --opt o=bind "$package_name-data"
        sudo podman volume create --opt device="$HOME/.config/containers/$package_name/extensions" --opt type=none --opt o=bind "$package_name-extensions"

        sudo podman run -d \
        --name $package_name \
        --restart=unless-stopped \
        --log-opt max-size=10m \
        -p 8090:80 \
        -e TZ=Australia/Melbourne \
        -e 'CRON_MIN=1,31' \
        -v $package_name-data:/var/www/FreshRSS/data \
        -v $package_name-extensions:/var/www/FreshRSS/extensions \
        freshrss/freshrss

        if [[ $iptables_installed -eq 1 ]]; then
            echo "Creating firewall rules for $package_name..."
            sudo iptables -A INPUT -p tcp --dport 8090 -j ACCEPT
            save_firewall_rules
            echo "Firewall rules have been added to allow $package_name."
        fi

        append_line_to_file "$HOME/.config/containers/start.sh" "podman start $package_name"

        # Check if nginx is installed and add config
        if [[ $nginx_installed -eq 1 ]]; then
            echo "Adding nginx proxy settings for $package_name..."
            append_nginx_conf 8090 $package_name
        fi

        echo "Completed installing $package_name..."
    else
        echo "Skipping install and configuration of $package_name."
    fi
}


#       ------End of Containers -------

#--------------------------------------- End of Utility functions --------------------------------------

#------------------------------------- Pre and Post install methods-------------------------------------


post_install_default_jre() {
    echo "Verifying installation..."
    java --version
}

post_install_python3() {
    echo "Verifying installation..."
    python3 --version
}

post_install_pip3() {
    echo "Verifying installation..."
    pip3 --version
}

pre_install_nodejs() {
    echo "Updating repo for NodeJS"
    # curl -fsSL https://deb.nodesource.com/setup_currentversion.x | sudo -E bash -
    curl -fsSL https://deb.nodesource.com/setup_23.x | sudo -E bash -
    sudo apt update
}

post_install_nodejs() {
    echo "Verifying installation..."
    node -v
    npm -v
}

post_install_golang() {
    echo "Verifying installation..."
    go version
}

 pre_install_dotnet_sdk_8_0() {
    echo "Updating repo for dotnet-sdk-8.0"
    wget "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt update
}

post_install_dotnet_sdk_8_0() {
    echo "Verifying installation..."
    dotnet --list-sdks
}

pre_install_neovim() {
    echo "Updating repo for NeoVim"
    sudo add-apt-repository ppa:neovim-ppa/stable -y
    sudo apt update
}

post_install_neovim() {
    echo "Setting up NeoVim config"
    git clone https://github.com/febinjoy/febins-neovim-config.git ~/.config/nvim
}

post_install_tmux() {
    echo "Setting up TMUX"
    wget -O ~/.tmux.conf https://raw.githubusercontent.com/febinjoy/terminal-config/main/.tmux.conf

    echo "Installing TPM (Tmux Plugin Manager)..."
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
}

post_install_unattended_upgrades() {
    echo "Setting up Unattended upgrades"
    sudo dpkg-reconfigure -plow unattended-upgrades
}

post_install_git_delta() {
    echo "Setting up git-delta"
    download_file "https://raw.githubusercontent.com/dandavison/delta/main/themes.gitconfig" "$HOME/.config/delta/themes.gitconfig"
    append_git_delta_to_gitconfig
}

post_install_auditd() {
    echo "Setting up auditd"
    sudo systemctl enable auditd
    sudo systemctl start auditd
}

post_install_fail2ban() {
    echo "Setting up fail2ban"
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
}

post_install_lynsis() {
    sudo apt install libpam-tmpdir apt-listchanges -y
}

pre_install_nginx() {
    sudo apt update
}

post_install_nginx() {
    # set flag to true
    export nginx_installed=1
    get_nginx_host_details
    sudo mkdir -p /etc/nginx/conf.d
    sudo touch "/etc/nginx/conf.d/$nginx_hostname_domain.conf"
}

post_install_zsh() {
    echo "Setting up ZSH"
    sudo touch ~/.zsh_history
    download_file "https://raw.githubusercontent.com/febinjoy/terminal-config/blob/main/zshrc" "$HOME/.zshrc"
}

#--------------------------------- End of Pre and Post install methods----------------------------------

#---------------------------------------- Performing Installs ------------------------------------------

update
upgrade
echo "Installing git"
sudo apt install git -y

packages_to_install=("default-jre" "python3" "python3-pip" "python3-venv" "python3-debugpy" "nodejs" "golang" "lua5.4" "luarocks" "dotnet-sdk-8.0" "sqlite3")
install_packages "${packages_to_install[@]}"
configure_git
setup_ssh

packages_to_install=("net-tools" "bat" "unzip" "ripgrep" "grep" "xclip" "htop" "ranger" "iptables" "fzf" "neovim" "tmux" "unattended-upgrades" "git-delta")
install_packages "${packages_to_install[@]}"
install_lazygit
setup_ntp
setup_sshd
setup_firewall
packages_to_install=("auditd" "fail2ban" "lynis" "nginx")
install_packages "${packages_to_install[@]}"
install_configure_cockpit
setup_containers
packages_to_install=("zsh")
install_packages "${packages_to_install[@]}"
sudo apt autoremove
echo "All tasks are complete."
restart_server
#------------------------------------- End of Performing Installs --------------------------------------

