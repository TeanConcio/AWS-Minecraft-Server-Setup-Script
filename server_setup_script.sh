#!/bin/bash

setup_user_and_login() {
	# === CREATE USER AND KEY-BASED LOGIN ===
	
	id -u minecraft &>/dev/null || sudo adduser minecraft
	sudo -u minecraft mkdir -p /home/minecraft/.ssh
	sudo chmod 700 /home/minecraft/.ssh
	sudo chown minecraft:minecraft /home/minecraft/.ssh
	sudo cp /home/ec2-user/.ssh/authorized_keys /home/minecraft/.ssh/
	sudo chown minecraft:minecraft /home/minecraft/.ssh/authorized_keys
	sudo chmod 600 /home/minecraft/.ssh/authorized_keys
}

create_permission_group() {
	# === CREATE PERMISSION GROUP ===
	
	getent group minecraft-group || sudo groupadd minecraft-group
	sudo usermod -aG minecraft-group ec2-user
	sudo usermod -aG minecraft-group minecraft
	sudo tee /etc/profile.d/minecraft_umask.sh > /dev/null <<'EOF'
# Set umask for users in minecraft-group
if id -nG "${USER}" | grep -qw "minecraft-group"; then
    umask 007
fi
EOF
	sudo chmod 644 /etc/profile.d/minecraft_umask.sh
}

install_dependencies() {
	# === INSTALL Dependencies ===

	# Linux Utils, Java 17, Firewalld, Screen, Tuned
	sudo yum install -y util-linux java-17-amazon-corretto-headless firewalld screen tuned
	sudo systemctl enable --now firewalld

	# MCRCON Client
	sudo yum install -y git gcc make
	git clone https://github.com/Tiiffi/mcrcon.git /tmp/mcrcon
	cd /tmp/mcrcon
	make
	sudo cp mcrcon /usr/local/bin/
	rm -rf /tmp/mcrcon
}

optimize_machine() {
	# === OPTIMIZE MACHINE ===

	# Tuned Profiles
	sudo systemctl enable --now tuned
	sudo tuned-adm profile throughput-performance
	
	# Increase file descriptors ---
	sudo tee /etc/security/limits.d/minecraft.conf >/dev/null <<'EOF'
minecraft soft nofile 65535
minecraft hard nofile 65535
EOF

	# Network Tuning
	sudo mkdir -p /etc/sysctl.d
	sudo tee /etc/sysctl.d/99-minecraft.conf > /dev/null <<'EOF'
# Minecraft server networking & socket sanity
net.core.somaxconn = 1024
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_keepalive_time=600

# Optional but helpful socket buffers (safe defaults)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

EOF

	# Enable BBR Congestion Control if supported
	if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
		sudo tee -a /etc/sysctl.d/99-minecraft.conf >/dev/null <<'EOF'
# Enable BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

EOF
	fi

	# Apply sysctl changes immediately
	sudo sysctl --system
}

create_swap_space() {
    # === CREATE SWAP SPACE ===
    SWAP_SIZE_GB=4
    SWAP_FILE="/swapfile"
    SWAPPINESS=10

    # Use flock to prevent race conditions
    exec 9>/var/lock/swapfile.lock
    flock -n 9 || { echo "Another process is creating swapfile, exiting."; return; }

    if swapon --show | grep -q "${SWAP_FILE}"; then
        :  # Already active, do nothing
    else
        if [ ! -f "${SWAP_FILE}" ]; then
			if ! sudo fallocate -l ${SWAP_SIZE_GB}G ${SWAP_FILE} 2>/dev/null; then
				# fallocate failed, falling back to dd
				sudo dd if=/dev/zero of=${SWAP_FILE} bs=1M count=$((SWAP_SIZE_GB*1024)) status=progress
				sync
			fi
            sudo chmod 600 ${SWAP_FILE}
            sudo mkswap ${SWAP_FILE}
        fi
        sudo swapon ${SWAP_FILE}
		if ! grep -qE "^\s*${SWAP_FILE}\s" /etc/fstab; then
            echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
        fi
        sudo sysctl vm.swappiness=${SWAPPINESS}
        if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
            echo "vm.swappiness=${SWAPPINESS}" | sudo tee -a /etc/sysctl.conf
        fi
    fi
}

create_env_file() {
	# === ENVIRONMENT CONFIGURATION VARIABLES ===
	
	sudo tee /etc/minecraft.env > /dev/null <<'EOF'
SERVER_DIRECTORY="/opt/minecraft/server"

MINECRAFTSERVERURL="https://fill-data.papermc.io/v1/objects/234a9b32098100c6fc116664d64e36ccdb58b5b649af0f80bcccb08b0255eaea/paper-1.20.1-196.jar"
SERVER_JAR="paper-1.20.1-196.jar"
USE_HARDCODED_RAM=false
RESERVED_RAM_GB=1
MIN_MAX_RAM="15G"
SERVER_START_COMMAND='java -Dlog4j2.formatMsgNoLookups=true -Dterminal.jline=false -Dterminal.ansi=true -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true -Xms${MIN_MAX_RAM} -Xmx${MIN_MAX_RAM} -jar ${SERVER_JAR} nogui'

SERVER_PORT="25565"
RCON_PASSWORD="SECURE_SHIBAL_BOER_1989"
RCON_PORT="25575"

IDLE_FILE="${SERVER_DIRECTORY}/scripts/minecraft_idle_minutes"
IDLE_MINUTES_SHUTDOWN=5
MAX_ERROR_RETRIES=5
RETRY_INTERVAL=30
TIME_LOG_FILE="${SERVER_DIRECTORY}/scripts/minecraft_time_log"
EOF

	sudo chown root:minecraft-group /etc/minecraft.env
	sudo chmod 640 /etc/minecraft.env
	set -a
	source /etc/minecraft.env
	set +a
}

create_dir() {
	# === CREATE DIRECTORY  ===
	
	mkdir -p ${SERVER_DIRECTORY}
	sudo chown -R :minecraft-group ${SERVER_DIRECTORY}
	
	ALT_DIRECTORY="${SERVER_DIRECTORY/\/opt/\/home}"
	if [ ! -e "${ALT_DIRECTORY}" ]; then
        ln -s ${SERVER_DIRECTORY} ${ALT_DIRECTORY}
    else
        : # Symlink already exists, do nothing
    fi
	
	cd ${SERVER_DIRECTORY}
	mkdir data
	mkdir scripts
}

create_server_properties() {
	# === CREATE server.properties BEFORE FIRST LAUNCH ===
	
	cd ${SERVER_DIRECTORY}/data
	sudo tee server.properties > /dev/null <<EOF
# Minecraft server properties
server-port=${SERVER_PORT}
enable-rcon=true
rcon.password=${RCON_PASSWORD}
rcon.port=${RCON_PORT}
sync-chunk-writes=false
network-compression-threshold=512
simulation-distance=4
view-distance=7
EOF
}

initialize_server_eula() {
	# === DOWNLOAD SERVER JAR and INITIALIZE SERVER ===
	
	cd ${SERVER_DIRECTORY}/data

	# Download server jar
	wget ${MINECRAFTSERVERURL} -O ${SERVER_JAR} || { echo "Download failed"; exit 1; }

	# Initialize server to generate eula.txt
	sudo -u minecraft timeout 60s ${SERVER_START_COMMAND} || true
	ATTEMPTS=0
	while [ ! -f eula.txt ] && [ "${ATTEMPTS}" -lt "${MAX_ERROR_RETRIES}" ]; do
		sleep 10
		ATTEMPTS=$((ATTEMPTS + 1))
	done
	if [ ! -f eula.txt ]; then
		echo "EULA file not found after ${ATTEMPTS} attempts. Server may have failed to start."
		exit 1
	fi
	sed -i 's/eula=false/eula=true/' eula.txt
}

create_start_script() {
	# === CREATE START SCRIPT ===
	
	cd ${SERVER_DIRECTORY}/scripts
	sudo tee start_script.sh > /dev/null <<'EOF'
#!/bin/bash
source /etc/minecraft.env
cd ${SERVER_DIRECTORY}/data

# Remove stale instances
pkill -u minecraft -f "${SERVER_JAR}"
screen -S minecraft -X quit > /dev/null

# Dynamically set RAM
if [ "${USE_HARDCODED_RAM}" = "false" ]; then
	AVAILABLE_RAM=$(awk '/MemTotal/ {print int($2 / 1024 / 1024 + 1)}' /proc/meminfo)
	AVAILABLE_RAM=$((AVAILABLE_RAM - RESERVED_RAM_GB))
	
	if [ "${AVAILABLE_RAM}" -lt 2 ]; then
		logger -t minecraft-server "Start Script: Not enough memory."
		exit 1
	else
		MIN_MAX_RAM="${AVAILABLE_RAM}G"
		logger -t minecraft-server "Start Script: Not using hardcoded RAM. Found available RAM: ${MIN_MAX_RAM}."
	fi
else
	logger -t minecraft-server "Start Script: Using hardcoded RAM: ${MIN_MAX_RAM}."
fi

# Reevaluate server start command
eval "SERVER_START_COMMAND=\"${SERVER_START_COMMAND}\""

# Start Minecraft server in a detached screen session
logger -t minecraft-server "Start Script: Starting Minecraft server with command: ${SERVER_START_COMMAND}"
screen -dmS minecraft bash -c "exec ${SERVER_START_COMMAND}"
#exec ${SERVER_START_COMMAND}

sleep 10
pgrep -u minecraft -f "${SERVER_JAR}" || {
    logger -t minecraft-server "Start Script: Server failed to start."
    exit 1
}
EOF
}

create_stop_script() {
	# === CREATE STOP SCRIPT ===

	cd ${SERVER_DIRECTORY}/scripts
	sudo tee stop_script.sh > /dev/null <<'EOF'
#!/bin/bash
source /etc/minecraft.env
cd ${SERVER_DIRECTORY}/data

# Retry loop for RCON shutdown
for i in $(seq 1 ${MAX_ERROR_RETRIES}); do
    logger -t minecraft-server "Sending stop command via RCON..."
    timeout 60 mcrcon -H 127.0.0.1 -P ${RCON_PORT} -p "${RCON_PASSWORD}" stop && {
        logger -t minecraft-server "Stop command sent successfully."
		screen -S minecraft -X quit > /dev/null
        exit 0
    }
    logger -t minecraft-server "RCON failed. Retrying in ${RETRY_INTERVAL} seconds..."
    sleep ${RETRY_INTERVAL}
done

# Fallback process kill
logger -t minecraft-server "Failed to stop server after ${MAX_ERROR_RETRIES} attempts."
PID=$(pgrep -u minecraft -f "${SERVER_JAR}")
if [ -n "${PID}" ]; then
    if ps -p "${PID}" -o comm= | grep -q java; then
        kill -9 "${PID}"
        logger -t minecraft-server "Fallback: Killed Minecraft server process ${PID}."
		screen -S minecraft -X quit > /dev/null
        exit 0
    else
        logger -t minecraft-server "Fallback: PID ${PID} is not a Java process. Skipping kill."
        exit 1
    fi
else
    logger -t minecraft-server "Fallback: No Minecraft process found."
    exit 1
fi
EOF
}

create_idle_check_script() {
	# === CREATE IDLE CHECK SCRIPT ===

	cd ${SERVER_DIRECTORY}/scripts
	sudo tee idle_check_script.sh > /dev/null <<'EOF'
#!/bin/bash
source /etc/minecraft.env

# Lock to only 1 instance of check idle script
LOCK_FILE="${SERVER_DIRECTORY}/scripts/idle_check.lock"
if [ -f "${LOCK_FILE}" ]; then
    AGE=$(($(date +%s) - $(stat -c %Y "${LOCK_FILE}")))
    if [ "${AGE}" -gt 600 ]; then
        logger -t minecraft-idle-check "Stale lock detected. Removing."
        rm -f "${LOCK_FILE}"
    fi
fi
exec 200>"${LOCK_FILE}"
flock -n -w 20 200 || {
    logger -t minecraft-idle-check "Idle lock check: Lock wait timeout. Another instance may be running. Exiting."
    exit 1
}

# Declare minutes online (positive number = minutes of no players, negative number = minutes of server down)
if [ -f "${IDLE_FILE}" ]; then
	MINUTES=$(cat "${IDLE_FILE}")
else
	MINUTES=0
fi

# Check if server process is running
RCON_RESPONSE=""
if [ -z "$(pgrep -u minecraft -f ${SERVER_JAR})" ]; then
    # Reset if accumulating idle minutes
	if [ ${MINUTES} -gt 0 ]; then
		MINUTES=0
	fi
	MINUTES=$((MINUTES - 1))
	logger -t minecraft-idle-check "Offline check: Server process not running. ${MINUTES} / -${IDLE_MINUTES_SHUTDOWN} minute/s before shutdown."

else
	# RCON Query player list
	RCON_RESPONSE=$(timeout 20 mcrcon -H 127.0.0.1 -P ${RCON_PORT} -p "${RCON_PASSWORD}" list 2>/dev/null)
	#logger -t minecraft-idle-check "Player list: ${RCON_RESPONSE}"
fi

# Check if RCON command failed
if [ -z "${RCON_RESPONSE}" ]; then
	# Reset if accumulating idle minutes
	if [ ${MINUTES} -gt 0 ]; then
		MINUTES=0
	fi
	MINUTES=$((MINUTES - 1))
	logger -t minecraft-idle-check "Hang check: RCON failed or returned empty. ${MINUTES} / -${IDLE_MINUTES_SHUTDOWN} minute/s before shutdown."
	
# Check number of players
elif echo "${RCON_RESPONSE}" | grep -qE "\b0 of a max"; then
	# Reset if accumulating offline minutes
	if [ ${MINUTES} -lt 0 ]; then
		MINUTES=0
	fi
	MINUTES=$((MINUTES + 1))
	logger -t minecraft-idle-check "Idle check: No active players. ${MINUTES} / ${IDLE_MINUTES_SHUTDOWN} minute/s before shutdown."

# There are active players
else
	# Only reset and log if previous minutes is not zero
	if [ ${MINUTES} -ne 0 ]; then
		MINUTES=0
		logger -t minecraft-idle-check "Idle check: Found players. Resetting timer back to 0 / ${IDLE_MINUTES_SHUTDOWN} minute/s"
	fi

	# Log player play time by accumulating minutes
	if [ ! -f "${TIME_LOG_FILE}" ]; then
		touch "${TIME_LOG_FILE}"
	fi

	# Calculate increment based on player count per minute to get fractional time
	PLAYER_LIST=$(echo "${RCON_RESPONSE}" | awk -F: '{if (NF>1) print $2}' | sed 's/\x1b\[[0-9;]*m//g' | tr ', ' '\n' | grep -v '^\s*$')
	PLAYER_COUNT=$(echo "${PLAYER_LIST}" | grep -c .)
	INCREMENT=$(awk "BEGIN {printf \"%.4f\", 1/${PLAYER_COUNT}}")

	for PLAYER in ${PLAYER_LIST}; do

		# Get current time (default to 0 if not found)
		CURRENT_TIME=$(grep -F "${PLAYER}:" "${TIME_LOG_FILE}" | cut -d: -f2)
		if [ -z "${CURRENT_TIME}" ]; then
			CURRENT_TIME=0
		fi
		NEW_TIME=$(awk "BEGIN {printf \"%.4f\", ${CURRENT_TIME}+${INCREMENT}}")

		if grep -qE "^${PLAYER}:" "${TIME_LOG_FILE}"; then
			sed -i "s/^${PLAYER}:.*/${PLAYER}:${NEW_TIME}/" "${TIME_LOG_FILE}"
		else
			echo "${PLAYER}:${NEW_TIME}" >> "${TIME_LOG_FILE}"
		fi
	done
fi

# Check minutes for shutdown
if [ "${MINUTES}" -le "-${IDLE_MINUTES_SHUTDOWN}" ]; then
	logger -t minecraft-idle-check "Offline check: Server down for ${IDLE_MINUTES_SHUTDOWN} minutes. Shutting down..."
	echo 0 > "${IDLE_FILE}"
	rm -f "${LOCK_FILE}"
	sudo systemctl stop minecraft.service
	sudo /bin/systemctl start minecraft-shutdown.service
	
elif [ "${MINUTES}" -ge "${IDLE_MINUTES_SHUTDOWN}" ]; then
	logger -t minecraft-idle-check "Idle check: No active players for ${IDLE_MINUTES_SHUTDOWN} minutes. Shutting down..."
	echo 0 > "${IDLE_FILE}"
	rm -f "${LOCK_FILE}"
	sudo systemctl stop minecraft.service
	sudo /bin/systemctl start minecraft-shutdown.service

else
	echo "${MINUTES}" > "${IDLE_FILE}"
fi
EOF
}

give_proper_permissions() {
	# === GIVE PROPER PERMISSIONS ===
	
	# Give minecraft shutdown permissions
	echo "minecraft ALL=(ALL) NOPASSWD: /bin/systemctl start minecraft-shutdown.service" | sudo tee /etc/sudoers.d/minecraft-shutdown > /dev/null
	sudo chmod 440 /etc/sudoers.d/minecraft-shutdown

	# Give group permissions
	sudo setfacl -R -b ${SERVER_DIRECTORY}
	sudo chown -R :minecraft-group ${SERVER_DIRECTORY}
	sudo chmod -R 770 ${SERVER_DIRECTORY}
	sudo setfacl -R -m g:minecraft-group:rwx ${SERVER_DIRECTORY}
	sudo setfacl -R -m d:g:minecraft-group:rwx ${SERVER_DIRECTORY}

	# Open firewall ports
	sudo firewall-cmd --permanent --add-port=${SERVER_PORT}/tcp
	sudo firewall-cmd --permanent --add-port=${RCON_PORT}/tcp
	sudo firewall-cmd --reload
	sleep 10
}

create_minecraft_service() {
	# === CREATE minecraft.service ===
	
	sudo tee /etc/systemd/system/minecraft.service > /dev/null <<EOF
[Unit]
Description=Minecraft Server on start up
Requires=network-online.target
After=network-online.target
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=forking
PermissionsStartOnly=true
User=minecraft
WorkingDirectory=${SERVER_DIRECTORY}/data
EnvironmentFile=/etc/minecraft.env
ExecStartPre=/bin/sh -c "echo madvise > /sys/kernel/mm/transparent_hugepage/enabled"
ExecStartPre=/bin/sh -c "echo madvise > /sys/kernel/mm/transparent_hugepage/defrag"
ExecStartPre=/usr/bin/test -f ${SERVER_DIRECTORY}/data/${SERVER_JAR}
ExecStartPre=/usr/bin/test -r /etc/minecraft.env
ExecStart=${SERVER_DIRECTORY}/scripts/start_script.sh
ExecStop=${SERVER_DIRECTORY}/scripts/stop_script.sh
ExecStopPost=/usr/bin/screen -S minecraft -X quit
TimeoutStopSec=300
Restart=on-failure
RestartSec=30
StandardInput=null
StandardOutput=journal
StandardError=journal
SyslogIdentifier=minecraft-server
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

create_check_idle_service_timer() {
	# === CREATE SYSTEMD SERVICE AND TIMER FOR IDLE CHECK ===

	# minecraft-idle-check.service
	sudo tee /etc/systemd/system/minecraft-idle-check.service > /dev/null <<EOF
[Unit]
Description=Check if Minecraft server is idle

[Service]
Type=oneshot
ExecStart=${SERVER_DIRECTORY}/scripts/idle_check_script.sh
SyslogIdentifier=minecraft-idle-check
EOF

	# minecraft-idle-check.timer
	sudo tee /etc/systemd/system/minecraft-idle-check.timer > /dev/null <<EOF
[Unit]
Description=Run Minecraft idle check every 1 minute

[Timer]
OnBootSec=5min
OnCalendar=*-*-* *:*:00
Unit=minecraft-idle-check.service

[Install]
WantedBy=timers.target
EOF
}

create_shutdown_service() {
	# === CREATE SYSTEMD SERVICE FOR SHUTDOWN ===

	# minecraft-shutdown.service
	sudo tee /etc/systemd/system/minecraft-shutdown.service > /dev/null <<EOF
[Unit]
Description=Shutdown the system when Minecraft requests it
Requires=multi-user.target
After=multi-user.target
Conflicts=minecraft.service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl poweroff
EOF
}

enable_startups() {

	sudo systemctl daemon-reload
	sudo systemctl enable minecraft.service
	sudo systemctl enable --now minecraft-idle-check.timer
	
	#sudo systemctl start minecraft.service
}



# === SCRIPT PIPELINE ===
setup_user_and_login
create_permission_group
install_dependencies
optimize_machine
create_swap_space
create_env_file
create_dir
create_server_properties
initialize_server_eula
create_start_script
create_stop_script
create_idle_check_script
give_proper_permissions
create_minecraft_service
create_check_idle_service_timer
create_shutdown_service
enable_startups

# === END OF SCRIPT ===



# I am making a set up script for an AWS EC2 linux Minecraft server with an idle minutes timer to shut down the machine automatically to save on resources. May I ask if it is correct and functional, and if there are any edge cases or race conditions I need to take note of? Additionally, aside from adding JVM parameters, modifying server.properties, adding optimization mods, enabling swapping, adding more RAM, and other optimizations in the script, are there any other ways I can improve the server's performance and making it safer? I will be sending my script in the succeeding prompts.