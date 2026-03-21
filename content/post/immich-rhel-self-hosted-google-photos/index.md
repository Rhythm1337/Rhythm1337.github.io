---
title: "Self-Hosting Google Photos with Immich on RHEL and Podman"
description: "Turning an old laptop into a private photo backup with Immich, rootless , SELinux, and Tailscale on RHEL"
date: 2026-03-17
draft: false
categories:
    - Projects
tags:
    - RHEL
    - Podman
    - Immich
    - SELinux
    - Tailscale
    - Self-Hosting
    - Homelab
image: thumbnail.png
---

- Showcase video: https://www.youtube.com/watch?v=FrCaie-2YKk

## Introductions

I wanted to set up a simple self-hosted photo backup server with Immich on RHEL.

Most Immich guides are written for setups that do not have to deal with RHEL-specific SELinux behavior. The installation itself is not too bad, but getting the permissions right can be frustrating if you have never done it before.

This post walks through how to run Immich on RHEL with rootless Podman and Tailscale, with the extra steps needed to make it work cleanly.

## Step 1: Download the Immich Files (default setup)

First, create the working directory and pull down the official Immich deployment files.

```bash
# Create the directory for Immich
mkdir ./immich-app

# Navigate into the directory
cd ./immich-app

# Download the docker-compose.yml file
wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml

# Download the example .env file
wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
```

## Step 2: Install podman-compose

Now we need a way to run this compose file. RHEL keeps its official repositories incredbly strict for enterprise stability. To get community-standard tools like `podman-compose`, we have to switch to root, enable CodeReady Builder (CRB), and get into Fedora's Extra Packages for Enterprise Linux (EPEL).

```bash
# Switch to root
su -

# Enable CRB and install EPEL
subscription-manager repos --enable codeready-builder-for-rhel-10-$(arch)-rpms
dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
logout

# Install podman-compose
sudo dnf install podman-compose
```

Tip: If the CRB repository does not work, you can always bypass it by installing `pip` and installing `podman-compose` through Python instead.

```bash
sudo dnf install python3-pip
pip3 install --user podman-compose
```

## Step 3: Edit SELinux Contexts

Next, edit the `docker-compose.yml` file. Because RHEL uses SELinux, it blocks containers from touching host files. We have to explicitly add permissions to the volume mounts inside the file.

```bash
vim docker-compose.yml
```

```bash
 19     volumes:
 20       # Do not edit the next line. If you want to change the media storage location on your system, edit the value of UPLOAD_LOCATION in th    e .env file
 21       - ${UPLOAD_LOCATION}:/data:z
 22       - /etc/localtime:/etc/localtime:ro
 -
 67     volumes:
 68       # Do not edit the next line. If you want to change the database storage location on your system, edit the value of DB_DATA_LOCATION i    n the .env file
 69       - ${DB_DATA_LOCATION}:/var/lib/postgresql/data:z
 ```

When you are defining your volume paths in the compose file, append the correct SELinux labels:

- Add a lowercase `:z` to your photo uploads and database volume folder so multiple Immich containers can share that directory without locking each other out.

## Step 4: Fix PostgreSQL Permissions for Rootless Podman

Before starting the server, there is one major catch with rootless Podman. Because we are running this securely as a normal user instead of `root`, the host machine doesn't recognize the container's internal PostgreSQL user. We have to translate those permissions.

```bash
podman unshare chown -R 999:999 ./postgres/
```

The `podman unshare` command drops us into the container's user namespace. It maps the container's internal database user to a large, unprivileged user ID on the host machine, fixing the permission-denied errors without compromising security.

## Step 5: Fire It Up

With the permissions locked in and the files configured, start the stack in detached mode.

```bash
podman-compose up -d
```

## Step 6: Secure Remote Access with Tailscale

The server is running, but how do you access it securely without exposing ports to the internet? Tailscale makes this effortless.

Install Tailscale using their official script:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Once installed, bring the node online:

```bash
sudo tailscale up
```

Copy the authentication link provided in the terminal, paste it into your browser, and authenticate. That's it. Anything connected to your Tailscale mesh network can now access your new Immich instance securely.

# Convert Containers Into a Service with Quadlet

If you want to convert your containers into a proper user service, follow these steps. With the following steps, you can have immich auto start if the system restarts and so on.

## Step 7: Transition to Quadlet (Kubernetes Style)

We can use Quadlet to treat the containers as a native systemd service. First, generate a Kubernetes YAML blueprint from the stack.

```bash
# Start the stack once to group services into a Pod
podman-compose up -d

# Export the running Pod to a K8s manifest
podman kube generate pod_immich > ~/immich-app/immich.yaml
podman-compose down
```

## Step 8: Networking in a Pod

Inside a Pod, containers share the same network stack. That means Immich needs to resolve `database` and `redis` to `127.0.0.1`. Add this to `immich.yaml`.

```yaml
spec:
  hostAliases:
  - ip: "127.0.0.1"
    hostnames:
    - "database"
    - "redis"
```

## Step 9: Configure Quadlet

Move your manifest to the systemd generator directory and create the `.kube` file.

```bash
mkdir -p ~/.config/containers/systemd/
mv ~/immich-app/immich.yaml ~/.config/containers/systemd/

# Create the service definition
vim ~/.config/containers/systemd/immich.kube
```

`immich.kube` content:

```ini
[Unit]
Description=Immich Kubernetes Pod Quadlet
After=network-online.target

[Kube]
Yaml=immich.yaml

[Install]
WantedBy=default.target
```

## Step 10: Enable and Boot

Enable lingering so the service keeps running even when you are not logged in, then start it.

```bash
sudo loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user start immich.service
```

## Verification

Check logs with:

```bash
journalctl --user -xeu immich.service
systemctl --user status immich.service
```

If you see `database system is ready`, the service is up.