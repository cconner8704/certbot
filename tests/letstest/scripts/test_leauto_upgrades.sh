#!/bin/bash -xe
set -o pipefail

# $OS_TYPE $PUBLIC_IP $PRIVATE_IP $PUBLIC_HOSTNAME $BOULDER_URL
# are dynamically set at execution

cd letsencrypt

if ! command -v git ; then
    if [ "$OS_TYPE" = "ubuntu" ] ; then
        sudo apt-get update
    fi
    if ! (  sudo apt-get install -y git || sudo yum install -y git-all || sudo yum install -y git || sudo dnf install -y git ) ; then
        echo git installation failed!
        exit 1
    fi
fi
# 0.5.0 is the oldest version of letsencrypt-auto that can be used because it's
# the first version that pins package versions, properly supports
# --no-self-upgrade, and works with newer versions of pip.
git checkout -f v0.5.0 letsencrypt-auto
if ! ./letsencrypt-auto -v --debug --version --no-self-upgrade 2>&1 | grep 0.5.0 ; then
    echo initial installation appeared to fail
    exit 1
fi

# Now that python and openssl have been installed, we can set up a fake server
# to provide a new version of letsencrypt-auto. First, we start the server and
# directory to be served.
MY_TEMP_DIR=$(mktemp -d)
PORT_FILE="$MY_TEMP_DIR/port"
SERVER_PATH=$(tools/readlink.py tools/simple_http_server.py)
cd "$MY_TEMP_DIR"
"$SERVER_PATH" 0 > $PORT_FILE &
SERVER_PID=$!
trap 'kill "$SERVER_PID" && rm -rf "$MY_TEMP_DIR"' EXIT
cd ~-

# Then, we set up the files to be served.
FAKE_VERSION_NUM="99.99.99"
echo "{\"releases\": {\"$FAKE_VERSION_NUM\": null}}" > "$MY_TEMP_DIR/json"
LE_AUTO_SOURCE_DIR="$MY_TEMP_DIR/v$FAKE_VERSION_NUM"
NEW_LE_AUTO_PATH="$LE_AUTO_SOURCE_DIR/letsencrypt-auto"
mkdir "$LE_AUTO_SOURCE_DIR"
cp letsencrypt-auto-source/letsencrypt-auto "$LE_AUTO_SOURCE_DIR/letsencrypt-auto"
SIGNING_KEY="letsencrypt-auto-source/tests/signing.key"
openssl dgst -sha256 -sign "$SIGNING_KEY" -out "$NEW_LE_AUTO_PATH.sig" "$NEW_LE_AUTO_PATH"

# Next, we wait for the server to start and get the port number.
sleep 5s
SERVER_PORT=$(sed -n 's/.*port \([0-9]\+\).*/\1/p' "$PORT_FILE")

# Finally, we set the necessary certbot-auto environment variables.
export LE_AUTO_DIR_TEMPLATE="http://localhost:$SERVER_PORT/%s/"
export LE_AUTO_JSON_URL="http://localhost:$SERVER_PORT/json"
export LE_AUTO_PUBLIC_KEY="-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsMoSzLYQ7E1sdSOkwelg
tzKIh2qi3bpXuYtcfFC0XrvWig071NwIj+dZiT0OLZ2hPispEH0B7ISuuWg1ll7G
hFW0VdbxL6JdGzS2ShNWkX9hE9z+j8VqwDPOBn3ZHm03qwpYkBDwQib3KqOdYbTT
uUtJmmGcuk3a9Aq/sCT6DdfmTSdP5asdQYwIcaQreDrOosaS84DTWI3IU+UYJVgl
LsIVPBuy9IcgHidUQ96hJnoPsDCWsHwX62495QKEarauyKQrJzFes0EY95orDM47
Z5o/NDiQB11m91yNB0MmPYY9QSbnOA9j7IaaC97AwRLuwXY+/R2ablTcxurWou68
iQIDAQAB
-----END PUBLIC KEY-----
"

if [ $(python -V 2>&1 | cut -d" " -f 2 | cut -d. -f1,2 | sed 's/\.//') -eq 26 ]; then
    if command -v python3; then
        echo "Didn't expect Python 3 to be installed!"
        exit 1
    fi
    cp letsencrypt-auto cb-auto
    if ! ./cb-auto -v --debug --version 2>&1 | grep 0.5.0 ; then
        echo "Certbot shouldn't have updated to a new version!"
        exit 1
    fi
    if [ -d "/opt/eff.org" ]; then
        echo "New directory shouldn't have been created!"
        exit 1
    fi
    # Create a 2nd venv at the new path to ensure we properly handle this case
    export VENV_PATH="/opt/eff.org/certbot/venv"
    if ! sudo -E ./letsencrypt-auto -v --debug --version --no-self-upgrade 2>&1 | grep 0.5.0 ; then
        echo second installation appeared to fail
        exit 1
    fi
    unset VENV_PATH
    EXPECTED_VERSION=$(grep -m1 LE_AUTO_VERSION certbot-auto | cut -d\" -f2)
    if ! ./cb-auto -v --debug --version -n | grep "$EXPECTED_VERSION" ; then
        echo "Certbot didn't upgrade as expected!"
        exit 1
    fi
    if ! command -v python3; then
        echo "Python3 wasn't properly installed"
        exit 1
    fi
    if [ "$(/opt/eff.org/certbot/venv/bin/python -V 2>&1 | cut -d" " -f 2 | cut -d. -f1)" != 3 ]; then
        echo "Python3 wasn't used in venv!"
        exit 1
    fi
elif ! ./letsencrypt-auto -v --debug --version || ! diff letsencrypt-auto letsencrypt-auto-source/letsencrypt-auto ; then
    echo upgrade appeared to fail
    exit 1
fi

echo upgrade appeared to be successful

if [ "$(tools/readlink.py ${XDG_DATA_HOME:-~/.local/share}/letsencrypt)" != "/opt/eff.org/certbot/venv" ]; then
    echo symlink from old venv path not properly created!
    exit 1
fi
echo symlink properly created
