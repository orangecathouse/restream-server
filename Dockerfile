ARG DEBIAN_VERSION=bullseye-slim 

##### Building stage #####
FROM debian:${DEBIAN_VERSION} as builder
MAINTAINER Vyacheslav Evstigneew <mail@evstigneew.com>

# Versions of nginx, rtmp-module and ffmpeg 
ARG  NGINX_VERSION=1.21.6
ARG  NGINX_RTMP_MODULE_VERSION=1.2.2
ARG  FFMPEG_VERSION=5.0

# Install dependencies
RUN apt-get update && \
	apt-get install -y \
		wget build-essential ca-certificates \
		openssl libssl-dev yasm git software-properties-common \
		libpcre3-dev librtmp-dev libtheora-dev \
		libvorbis-dev libvpx-dev libfreetype6-dev \
		libmp3lame-dev libx264-dev libx265-dev libass-dev \
		cmake libtool libc6 libc6-dev unzip libnuma1 libnuma-dev && \
	rm -rf /var/lib/apt/lists/*

# Download nginx source
RUN mkdir -p /tmp/build && \
	cd /tmp/build && \
	wget https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
	tar -zxf nginx-${NGINX_VERSION}.tar.gz && \
	rm nginx-${NGINX_VERSION}.tar.gz

# Download rtmp-module source
RUN cd /tmp/build && \
	wget https://github.com/arut/nginx-rtmp-module/archive/refs/tags/v${NGINX_RTMP_MODULE_VERSION}.tar.gz && \
	tar -zxf v${NGINX_RTMP_MODULE_VERSION}.tar.gz && \
	rm v${NGINX_RTMP_MODULE_VERSION}.tar.gz

# Build nginx with nginx-rtmp module
RUN cd /tmp/build/nginx-${NGINX_VERSION} && \
	./configure \
		--sbin-path=/usr/local/sbin/nginx \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \		
		--pid-path=/var/run/nginx/nginx.pid \
		--lock-path=/var/lock/nginx.lock \
		--http-client-body-temp-path=/tmp/nginx-client-body \
		--with-http_ssl_module \
		--with-threads \
		--add-module=/tmp/build/nginx-rtmp-module-${NGINX_RTMP_MODULE_VERSION} && \
	make -j $(getconf _NPROCESSORS_ONLN) && \
	make install

# Install CUDA
RUN apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/7fa2af80.pub && \
	add-apt-repository "deb https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/ /" && \
	add-apt-repository contrib && \
	apt-get clean && \
	apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get -y install cuda

# Download ffmpeg source
RUN cd /tmp/build && \
  wget http://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz && \
  tar -zxf ffmpeg-${FFMPEG_VERSION}.tar.gz && \
  rm ffmpeg-${FFMPEG_VERSION}.tar.gz

# Download ffnvcodec and compile
RUN cd /tmp/build && \
	git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git && \
	cd nv-codec-headers && \
	make -j $(getconf _NPROCESSORS_ONLN) && \
	make install

# Build ffmpeg
RUN cd /tmp/build/ffmpeg-${FFMPEG_VERSION} && \
  ./configure \
	  --enable-version3 \
	  --enable-gpl \
	  --enable-small \
	  --enable-libx264 \
	  --enable-libx265 \
	  --enable-libvpx \
	  --enable-libtheora \
	  --enable-libvorbis \
	  --enable-librtmp \
	  --enable-postproc \
	  --enable-swresample \ 
	  --enable-libfreetype \
	  --enable-libmp3lame \
	  --disable-debug \
	  --disable-doc \
	  --disable-ffplay \
	  --enable-nonfree \
	  --enable-cuda-nvcc \
	  --nvccflags="-gencode arch=compute_75,code=sm_75 -O2" \
	  --enable-libnpp \
	  --extra-cflags=-I/usr/local/cuda/include \
	  --extra-ldflags=-L/usr/local/cuda/lib64 \
	  --disable-static \
	  --enable-shared \
	  --extra-libs="-lpthread -lm" && \
	make -j $(getconf _NPROCESSORS_ONLN) && \
	make install
	
# Copy stats.xsl file to nginx html directory and cleaning build files
RUN cp /tmp/build/nginx-rtmp-module-${NGINX_RTMP_MODULE_VERSION}/stat.xsl /usr/local/nginx/html/stat.xsl && \
	rm -rf /tmp/build

##### Building the final image #####
FROM debian:${DEBIAN_VERSION}

# Install dependencies
RUN apt-get update && \
	apt-get install -y \
		ca-certificates openssl libpcre3-dev \
		librtmp1 libtheora0 libvorbis-dev libmp3lame0 \
		libvpx6 libx264-dev libx265-dev && \
	rm -rf /var/lib/apt/lists/*

# Copy files from build stage to final stage	
COPY --from=builder /usr/local /usr/local
COPY --from=builder /etc/nginx /etc/nginx
COPY --from=builder /var/log/nginx /var/log/nginx
COPY --from=builder /var/lock /var/lock
COPY --from=builder /var/run/nginx /var/run/nginx

# Forward logs to Docker
RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
	ln -sf /dev/stderr /var/log/nginx/error.log

# Copy  nginx config file to container
COPY conf/nginx.conf /etc/nginx/nginx.conf

# Copy  html players to container
#COPY players /usr/local/nginx/html/players

EXPOSE 1935
EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]