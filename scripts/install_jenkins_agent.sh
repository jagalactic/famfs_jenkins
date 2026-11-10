#!/bin/bash

fail () {
    set +x
    echo
    echo "*** Fail ***"
    echo "$TEST: $1"
    echo
    exit 1
}

# Variables
TARGET_HOST=$1
TARGET_USER=$2

if [  -z "$3" ]; then
    echo "usage: install_jenkins_agent host user secret"
    exit -1
fi

SECRET=$3

JENKINS_SERVER="jenkins-f40"
JENKINS_IP="192.168.122.163"  # Replace with the actual IP of the Jenkins server
SERVICE_NAME="jenkins-agent"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
#SERVICE_FILE=./$SERVICE_NAME.service
AGENT_JAR_PATH="/home/$TARGET_USER/agent.jar"  # Adjust as necessary
#AGENT_NAME="jmg"
WORK_DIR="/home/$TARGET_USER/$TARGET_HOST"

ssh $TARGET_HOST hostname || fail "unable to ssh to $TARGET_HOST"
ssh root@$TARGET_HOST hostname || fail "unable to ssh to $TARGET_HOST as root"

ssh ${TARGET_USER}@${TARGET_HOST} << EOF
    mkdir -p $WORK_DIR
EOF

# SSH into target host and perform the following tasks
ssh root@${TARGET_HOST} << EOF

# Check if Jenkins server is in /etc/hosts
if ! grep -q "$JENKINS_SERVER" /etc/hosts; then
	echo "$JENKINS_IP $JENKINS_SERVER" | sudo tee -a /etc/hosts
	echo "Added $JENKINS_SERVER to /etc/hosts"  
else
	echo "$JENKINS_SERVER is in /etc/hosts"
fi

EOF

# Create systemd service file
#sudo bash -c "cat > $SERVICE_FILE" << EOL


ssh root@${TARGET_HOST} << EOF
bash -c "cat > $SERVICE_FILE" << EOL
[Unit]
Description=Jenkins Agent Service
After=network.target

[Service]
ExecStart=/usr/bin/java -jar $AGENT_JAR_PATH -url http://$JENKINS_SERVER:8080/ -secret $SECRET -name $TARGET_HOST -workDir $WORK_DIR
User=$TARGET_USER
WorkingDirectory=$WORK_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF


ssh root@${TARGET_HOST} << EOF
    # Reload systemd, enable and start the service
    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME

    echo "Jenkins agent service installed and started on $TARGET_HOST."
EOF
