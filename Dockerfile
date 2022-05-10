# This is a two-stage Docker build where we use a more fully featured Debian
# image to build Marian and the required Python modules, then copy the built
# artifacts into a much smaller final image.

FROM debian:buster as builder

WORKDIR /usr/src/app

# Install base packages
RUN set -eux; \
    sh -c 'echo deb http://deb.debian.org/debian buster-backports main > /etc/apt/sources.list.d/buster-backports.list'; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates git wget gnupg build-essential lsb-release g++ \
		automake autogen libtool cmake-data cmake unzip \
		libboost-all-dev libblas-dev libopenblas-dev libz-dev libssl-dev \
		libprotobuf23 protobuf-compiler libprotobuf-dev \
		python3-dev python3-pip python3-setuptools python3-websocket python3-venv;

# Install Intel libraries
# RUN set -eux; \
# 	wget https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS-2019.PUB; \
# 	apt-key add GPG-PUB-KEY-INTEL-SW-PRODUCTS-2019.PUB; \
# 	sh -c 'echo deb https://apt.repos.intel.com/mkl all main > /etc/apt/sources.list.d/intel-mkl.list';\
# 	apt-get update; \
# 	apt-get install -y --no-install-recommends \
# 		intel-mkl-64bit-2019.5-075; \
# 	rm -f GPG-PUB-KEY-INTEL-SW-PRODUCTS-2019.PUB;


# Build Marian, using static libraries so we can simply pluck the compiled
# marian-server out later
# RUN set -eux; \
# 	apt-get install -y --no-install-recommends software-properties-common dialog apt-utils;
# RUN apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/debian10/x86_64/3bf863cc.pub; \
# 	add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/debian10/x86_64/ /"; 
# RUN add-apt-repository contrib;

# RUN apt-get update;
# RUN DEBIAN_FRONTEND=noninteractive apt-get -y -q install cuda;


# Build Marian, using static libraries so we can simply pluck the compiled
# marian-server out later
# RUN set -eux; \
# 	git clone https://github.com/marian-nmt/marian marian; \
# 	cd marian; \
# 	git checkout 1.9.0; \
# 	cmake . -DUSE_STATIC_LIBS=on -DCOMPILE_SERVER=on -DUSE_SENTENCEPIECE=on -DCOMPILE_CPU=off -DCOMPILE_CUDA=on;  \
# 	make -j4 marian_server ;

COPY requirements.txt .

# Install python requirements.  First we upgrade to the latest pip so it can
# support "manylinux2014" binary wheels.

RUN set -eux; \
        python3 -mvenv venv ; venv/bin/pip install --upgrade pip ; \
	venv/bin/pip install -r requirements.txt


# Start over from the minimal "slim" python base image
FROM nvidia/cuda:10.2-devel-ubuntu18.04 as marian_builder

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
        automake  \
        build-essential \
        curl \
        git-core  \
        libbz2-dev  \
        libsparsehash-dev \
        libtool  \
        perl \
        pkg-config  \
        unzip \
        wget \
        zlib1g-dev  \
		build-essential libboost-system-dev libprotobuf10 protobuf-compiler \
		libprotobuf-dev openssl libssl-dev libgoogle-perftools-dev \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

RUN wget https://github.com/Kitware/CMake/releases/download/v3.15.5/cmake-3.15.5-Linux-x86_64.sh \
    && yes y | bash cmake-3.15.5-Linux-x86_64.sh \
    && ln -s //cmake-3.15.5-Linux-x86_64/bin/* /usr/local/bin


# RUN git clone https://github.com/marian-nmt/marian.git
# ENV MARIANPATH /marian
# WORKDIR $MARIANPATH
# RUN mkdir -p build
# WORKDIR $MARIANPATH/build
# RUN cmake $MARIANPATH -DCMAKE_BUILD_TYPE=release -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda/ \
#  -DUSE_STATIC_LIBS=on -DCOMPILE_SERVER=on -DUSE_SENTENCEPIECE=on -DCUDA_INCLUDE_DIRS=/usr/local/cuda/lib64/ \
#   && make -j $(nproc);

WORKDIR /usr/src/app

RUN set -eux; \
	git clone https://github.com/marian-nmt/marian marian; \
	cd marian; \
	git checkout 1.9.0; \
	cmake . -DUSE_STATIC_LIBS=on -DCOMPILE_SERVER=on -DUSE_SENTENCEPIECE=on -DCOMPILE_CPU=off -DCOMPILE_CUDA=on \
	-DCMAKE_BUILD_TYPE=release -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda/ \
	-DCUDA_INCLUDE_DIRS=/usr/local/cuda/lib64/ ; \
	make -j$(nproc) marian_server ;


FROM nvidia/cuda:10.2-runtime-ubuntu18.04

WORKDIR /usr/src/app

# Include just the marian-server binary and the Python virtual environment from
# the build image - we don't need all the Marian sources, intermediate build
# artifacts, other Marian binaries, MKL libraries, etc.
COPY --from=marian_builder /usr/src/app/marian/marian-server /usr/local/bin
COPY --from=builder /usr/src/app/venv /usr/src/app/venv/

RUN ls -la /usr/src/app/venv/bin/
# Install base packages
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends python3.7;

# Install perl modules required by moses, and fix up the venv as python is
# in a different place in the "python" base image compared to where apt
# installs it in debian:stable
RUN set -ex ; \
	apt-get update; \
	apt-get install -y --no-install-recommends perl ; \
        rm -rf /var/lib/apt/lists/* ; \
        ln -sf /usr/bin/python3.7 /usr/src/app/venv/bin/python3

COPY . .

EXPOSE 80

# Run using the virtual environment Python
CMD ["venv/bin/python3", "server.py", "-c", "services.json", "-p", "80"]