# Builds the guest-side VA-API driver and the DRM stand-in shim (linux, glibc).
CFLAGS ?= -O2 -g0
CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter -fPIC -fvisibility=hidden
OUT ?= out

DRIVER_SRC = src/mdock_drv.c src/rpc.c src/bits.c src/h264.c src/hevc.c
DRIVER_HDR = src/rpc.h src/bits.h src/codec.h

all: $(OUT)/mdock_drv_video.so $(OUT)/libmdock_drm_shim.so

$(OUT)/mdock_drv_video.so: $(DRIVER_SRC) $(DRIVER_HDR)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -shared -Wl,-z,defs -Wl,--as-needed -o $@ $(DRIVER_SRC) -lpthread

# No libc on the link line: no DT_NEEDED and unversioned symbols, so glibc and musl both load it.
$(OUT)/libmdock_drm_shim.so: src/drm_shim.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -shared -nostdlib -o $@ src/drm_shim.c

clean:
	rm -rf $(OUT)

.PHONY: all clean

# Transport benchmark (not shipped).
$(OUT)/vtbench: src/vtbench.c src/rpc.c src/rpc.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ src/vtbench.c src/rpc.c -lpthread
