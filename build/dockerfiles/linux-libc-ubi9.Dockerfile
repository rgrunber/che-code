# Copyright (c) 2024 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

# https://registry.access.redhat.com/ubi9/nodejs-20
FROM registry.access.redhat.com/ubi9/nodejs-20:9.6-1749604222 as linux-libc-ubi9-builder

USER root

# Export GITHUB_TOKEN into environment variable
ARG GITHUB_TOKEN=''
ENV GITHUB_TOKEN=$GITHUB_TOKEN

# Unset GITHUB_TOKEN environment variable if it is empty.
# This is needed for some tools which use this variable and will fail with 401 Unauthorized error if it is invalid.
# For example, vscode ripgrep downloading is an example of such case.
RUN if [ -z $GITHUB_TOKEN ]; then unset GITHUB_TOKEN; fi

# Install libsecret-devel on s390x and ppc64le for keytar build (binary included in npm package for x86)
RUN { if [[ $(uname -m) == "s390x" ]]; then LIBSECRET="\
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/s390x/os/Packages/libsecret-0.20.4-4.el9.s390x.rpm \
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/s390x/os/Packages/libsecret-devel-0.20.4-4.el9.s390x.rpm"; \
    elif [[ $(uname -m) == "ppc64le" ]]; then LIBSECRET="\
      libsecret \
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/ppc64le/os/Packages/libsecret-devel-0.20.4-4.el9.ppc64le.rpm"; \
    elif [[ $(uname -m) == "x86_64" ]]; then LIBSECRET="\
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/x86_64/os/Packages/libsecret-devel-0.20.4-4.el9.x86_64.rpm \
      libsecret"; \
    elif [[ $(uname -m) == "aarch64" ]]; then LIBSECRET="\
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/aarch64/os/Packages/libsecret-devel-0.20.4-4.el9.aarch64.rpm \
      libsecret"; \
    else \
      LIBSECRET=""; echo "Warning: arch $(uname -m) not supported"; \
    fi; } \
    && { if [[ $(uname -m) == "x86_64" ]]; then LIBKEYBOARD="\
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/x86_64/os/Packages/libxkbfile-1.1.0-8.el9.x86_64.rpm \
      https://rpmfind.net/linux/centos-stream/9-stream/CRB/x86_64/os/Packages/libxkbfile-devel-1.1.0-8.el9.x86_64.rpm"; \
    elif [[ $(uname -m) == "ppc64le" ]]; then LIBKEYBOARD="\
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/ppc64le/os/Packages/libxkbfile-1.1.0-8.el9.ppc64le.rpm \
      https://rpmfind.net/linux/centos-stream/9-stream/CRB/ppc64le/os/Packages/libxkbfile-devel-1.1.0-8.el9.ppc64le.rpm"; \
    elif [[ $(uname -m) == "aarch64" ]]; then LIBKEYBOARD="\
      https://rpmfind.net/linux/centos-stream/9-stream/AppStream/aarch64/os/Packages/libxkbfile-1.1.0-8.el9.aarch64.rpm \
      https://rpmfind.net/linux/centos-stream/9-stream/CRB/aarch64/os/Packages/libxkbfile-devel-1.1.0-8.el9.aarch64.rpm"; \
    else \
      LIBKEYBOARD=""; echo "Warning: arch $(uname -m) not supported"; \
    fi; } \
    && yum install -y $LIBSECRET $LIBKEYBOARD make cmake gcc gcc-c++ python3.9 git git-core-doc openssh less libX11-devel libxkbcommon krb5-devel bash tar gzip rsync patch npm \
    && yum -y clean all && rm -rf /var/cache/yum

#########################################################
#
# Copy Che-Code to the container
#
#########################################################
COPY code /checode-compilation
WORKDIR /checode-compilation
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# Initialize a git repository for code build tools
RUN git init .

# change network timeout (slow using multi-arch build)
RUN npm config set fetch-retry-mintimeout 100000 && npm config set fetch-retry-maxtimeout 600000

# Grab dependencies (and force to rebuild them)
RUN rm -rf /checode-compilation/node_modules && npm install --force

# Compile
RUN NODE_ARCH=$(echo "console.log(process.arch)" | node) \
    && NODE_VERSION=$(cat /checode-compilation/remote/.npmrc | grep target | cut -d '=' -f 2 | tr -d '"') \
    # cache node from this image to avoid to grab it from within the build
    && mkdir -p /checode-compilation/.build/node/v${NODE_VERSION}/linux-${NODE_ARCH} \
    && echo "caching /checode-compilation/.build/node/v${NODE_VERSION}/linux-${NODE_ARCH}/node" \
    && cp /usr/bin/node /checode-compilation/.build/node/v${NODE_VERSION}/linux-${NODE_ARCH}/node \
    && NODE_OPTIONS="--max-old-space-size=4096" ./node_modules/.bin/gulp vscode-reh-web-linux-${NODE_ARCH}-min \
    && cp -r ../vscode-reh-web-linux-${NODE_ARCH} /checode \
    # cache libbrotli from this image to provide it to a user's container
    && mkdir -p /checode/ld_libs && find /usr/lib64 -name 'libbrotli*' 2>/dev/null | xargs -I {} cp -t /checode/ld_libs {}

RUN chmod a+x /checode/out/server-main.js \
    && chgrp -R 0 /checode && chmod -R g+rwX /checode

### Beginning of tests
# Do not change line above! It is used to cut this section to skip tests

# Compile tests
RUN ./node_modules/.bin/gulp compile-extension:vscode-api-tests \
	compile-extension:markdown-language-features \
	compile-extension:typescript-language-features \
	compile-extension:emmet \
	compile-extension:git \
	compile-extension:ipynb \
	compile-extension-media \
  compile-extension:configuration-editing

# # Compile test suites
# https://github.com/microsoft/vscode/blob/cdde5bedbf3ed88f93b5090bb3ed9ef2deb7a1b4/test/integration/browser/README.md#compile
RUN if [ "$(uname -m)" = "x86_64" ]; then npm --prefix test/smoke run compile && npm --prefix test/integration/browser run compile; fi

# install test dependencies
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=0
RUN if [ "$(uname -m)" = "x86_64" ]; then npm run playwright-install; fi
# Install procps to manage to kill processes and centos stream repository
RUN if [ "$(uname -m)" = "x86_64" ]; then \
      ARCH=$(uname -m) && \
      yum install --nobest -y procps \
        https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/e/epel-release-9-10.el9.noarch.rpm \
        https://rpmfind.net/linux/centos-stream/9-stream/BaseOS/x86_64/os/Packages/centos-gpg-keys-9.0-23.el9.noarch.rpm \
        https://rpmfind.net/linux/centos-stream/9-stream/BaseOS/x86_64/os/Packages/centos-stream-repos-9.0-23.el9.noarch.rpm; \
    fi

RUN if [ "$(uname -m)" = "x86_64" ]; then \
      yum install -y chromium && \
      PLAYWRIGHT_CHROMIUM_PATH=$(echo /opt/app-root/src/.cache/ms-playwright/chromium-*/) && \
      rm "${PLAYWRIGHT_CHROMIUM_PATH}/chrome-linux/chrome" && \
      ln -s /usr/bin/chromium-browser "${PLAYWRIGHT_CHROMIUM_PATH}/chrome-linux/chrome"; \
    fi

# use of retry and timeout
COPY /build/scripts/helper/retry.sh /opt/app-root/src/retry.sh
RUN chmod u+x /opt/app-root/src/retry.sh

# Run integration tests (Browser)
RUN if [ "$(uname -m)" = "x86_64" ]; then \
      NODE_ARCH=$(echo "console.log(process.arch)" | node) \
      VSCODE_REMOTE_SERVER_PATH="$(pwd)/../vscode-reh-web-linux-${NODE_ARCH}" \
      /opt/app-root/src/retry.sh -v -t 3 -s 2 -- timeout -v 5m ./scripts/test-web-integration.sh --browser chromium; \
    fi

# Run smoke tests (Browser)
RUN if [ "$(uname -m)" = "x86_64" ]; then \
      NODE_ARCH=$(echo "console.log(process.arch)" | node) \
      VSCODE_REMOTE_SERVER_PATH="$(pwd)/../vscode-reh-web-linux-${NODE_ARCH}" \
      /opt/app-root/src/retry.sh -v -t 3 -s 2 -- timeout -v 5m npm run smoketest-no-compile -- --web --headless --electronArgs="--disable-dev-shm-usage --use-gl=swiftshader"; \
    fi

# Do not change line below! It is used to cut this section to skip tests
### Ending of tests

#########################################################
#
# Copy VS Code launcher to the container
#
#########################################################
COPY launcher /checode-launcher
WORKDIR /checode-launcher
RUN npm install \
    && mkdir /checode/launcher \
    && cp -r out/src/*.js /checode/launcher \
    && chgrp -R 0 /checode && chmod -R g+rwX /checode

# Store the content of the result
FROM scratch as linux-libc-content
COPY --from=linux-libc-ubi9-builder /checode /checode-linux-libc/ubi9
