# wmtr macOS-side build.
#   make host     libwmtr_host.dylib (arm64): host executor + DXMT's winemetal_unix.c + airconv
#   make test     build and run tests/wmtr_loopback
# Linux (x86-64 build box, CC=gcc):
#   make client-linux  winemetal.so (x86-64 ELF): guest client unixlib (virtio-gpu transport), glibc <= 2.14 symbols
#   make test-linux    build and run tests/wmtr_ntdll_test against it
# Inputs: DXMT source at the pinned revision (DXMT=), its native build dir with libairconv.a (DXMT_BUILD=),
# LLVM 15 static libs (LLVM=), static zstd (ZSTD_LIB=). Machine-specific values can go in local.mk (not tracked).
-include local.mk
DXMT ?= ../work/src/dxmt
DXMT_BUILD ?= $(DXMT)/build-native
LLVM ?= ../work/out/host/llvm15
ZSTD_LIB ?= $(shell pkg-config --variable=libdir libzstd 2>/dev/null)/libzstd.a
OUT ?= build
CC = clang

INC = -Iinclude -Isrc -I../host/vrhost/include -I../guest/vr/include -I$(DXMT)/src/winemetal -I$(DXMT)/src/airconv
CFLAGS = -O2 -g -Wall -Wno-unused-function $(INC)
FRAMEWORKS = -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework Cocoa \
             -framework CoreGraphics -framework ColorSync -framework CoreFoundation -framework IOSurface
LLVM_LIBS = -L$(LLVM)/lib -lLLVMPasses -lLLVMTarget -lLLVMObjCARCOpts -lLLVMCoroutines -lLLVMipo \
  -lLLVMInstrumentation -lLLVMVectorize -lLLVMLinker -lLLVMIRReader -lLLVMAsmParser -lLLVMFrontendOpenMP \
  -lLLVMScalarOpts -lLLVMInstCombine -lLLVMAggressiveInstCombine -lLLVMTransformUtils -lLLVMBitWriter \
  -lLLVMAnalysis -lLLVMProfileData -lLLVMSymbolize -lLLVMDebugInfoPDB -lLLVMDebugInfoMSF -lLLVMDebugInfoDWARF \
  -lLLVMObject -lLLVMTextAPI -lLLVMMCParser -lLLVMMC -lLLVMDebugInfoCodeView -lLLVMBitReader -lLLVMCore \
  -lLLVMRemarks -lLLVMBitstreamReader -lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle \
  $(ZSTD_LIB) -lz -lcurses -lxml2 -lc++
AIRCONV = $(DXMT_BUILD)/src/airconv/darwin/libairconv.a $(DXMT_BUILD)/libs/DXBCParser/libDXBCParserNative.a

all: host

$(OUT):
	mkdir -p $(OUT)

# DXMT's unix side, unchanged; its unix-call table becomes wmtr_impl_funcs
$(OUT)/winemetal_unix.o: $(DXMT)/src/winemetal/unix/winemetal_unix.c | $(OUT)
	$(CC) $(CFLAGS) -ObjC -D__wine_unix_call_funcs=wmtr_impl_funcs -D__wine_unix_call_wow64_funcs=wmtr_impl_wow64_funcs \
	  -Wno-deprecated-declarations -c $< -o $@
$(OUT)/cache.o: $(DXMT)/src/winemetal/unix/cache.c | $(OUT)
	$(CC) $(CFLAGS) -ObjC -c $< -o $@
$(OUT)/wmtr_host.o: src/wmtr_host.m include/*.h src/wmtr_calls.inc src/wmtr_objects.h src/wmtr_objects.inc src/wmtr_object_cmds.inc | $(OUT)
	$(CC) $(CFLAGS) -ObjC -c $< -o $@
$(OUT)/wmtr_vr.o: src/wmtr_vr.m include/wmtr_vr.h ../host/vrhost/include/vrlink.h | $(OUT)
	$(CC) $(CFLAGS) -ObjC -c $< -o $@

host: $(OUT)/libwmtr_host.dylib
$(OUT)/libwmtr_host.dylib: $(OUT)/wmtr_host.o $(OUT)/wmtr_vr.o $(OUT)/winemetal_unix.o $(OUT)/cache.o $(AIRCONV)
	$(CC) -dynamiclib -install_name @rpath/libwmtr_host.dylib -o $@ $^ $(LLVM_LIBS) $(FRAMEWORKS) -lsqlite3
	codesign -s - -f $@

test: $(OUT)/wmtr_loopback $(OUT)/wmtr_present_test $(OUT)/wmtr_spin_test $(OUT)/wmtr_lifetime_test $(OUT)/wmtr_dxmt_test $(OUT)/dxmt_test.metallib
	./$(OUT)/wmtr_loopback
	WMTR_TEST_TRIGGER=1 ./$(OUT)/wmtr_loopback
	WMTR_CLIENT_HANDLES=0 ./$(OUT)/wmtr_loopback
	./$(OUT)/wmtr_present_test
	./$(OUT)/wmtr_spin_test
	./$(OUT)/wmtr_lifetime_test
	./$(OUT)/wmtr_dxmt_test $(OUT)/dxmt_test.metallib
$(OUT)/wmtr_lifetime_test: tests/wmtr_lifetime_test.m src/wmtr_host.m src/wmtr_objects.h src/wmtr_objects.inc src/wmtr_object_cmds.inc src/wmtr_vr.m include/*.h | $(OUT)
	$(CC) $(CFLAGS) -o $@ tests/wmtr_lifetime_test.m src/wmtr_vr.m -framework Foundation -framework Metal -framework Cocoa -framework QuartzCore -framework IOSurface
$(OUT)/wmtr_spin_test: tests/wmtr_spin_test.c include/wmtr_spin.h | $(OUT)
	$(CC) -O2 -Wall $(INC) -o $@ tests/wmtr_spin_test.c -lpthread
$(OUT)/wmtr_present_test: tests/wmtr_present_test.m $(OUT)/libwmtr_host.dylib
	$(CC) $(CFLAGS) -o $@ tests/wmtr_present_test.m -L$(OUT) -lwmtr_host -Wl,-rpath,@executable_path -framework Cocoa -framework Metal -framework QuartzCore
# DXMT's own guest API (winemetal_thunks.c) over the wmtr client into the production libwmtr_host
$(OUT)/wmtr_dxmt_test: tests/wmtr_dxmt_test.m tests/dxmt-shim/wineunixlib.h src/wmtr_client.c include/*.h src/*.inc $(OUT)/libwmtr_host.dylib
	$(CC) -Itests/dxmt-shim $(CFLAGS) -DNDEBUG -o $@ tests/wmtr_dxmt_test.m src/wmtr_client.c $(DXMT)/src/winemetal/winemetal_thunks.c \
	  -L$(OUT) -lwmtr_host -Wl,-rpath,@executable_path -framework Foundation -framework Metal -framework QuartzCore
$(OUT)/dxmt_test.metallib: tests/dxmt_test.metal | $(OUT)
	xcrun -sdk macosx metal -o $@ $<
$(OUT)/wmtr_loopback: tests/wmtr_loopback.m src/wmtr_host.m src/wmtr_objects.h src/wmtr_objects.inc src/wmtr_object_cmds.inc src/wmtr_vr.m src/wmtr_client.c include/*.h | $(OUT)
	$(CC) $(CFLAGS) -DWMTR_TESTING -o $@ tests/wmtr_loopback.m src/wmtr_host.m src/wmtr_vr.m src/wmtr_client.c -framework Foundation -framework Metal -framework Cocoa -framework QuartzCore -framework IOSurface

# -mtls-dialect=gnu: newer GCC defaults to TLS descriptors, which need GLIBC_ABI_GNU2_TLS (absent in the
# Steam Runtime's and the FEX rootfs's glibc), so the unixlib would not load
LINUX_CFLAGS = -O2 -g -Wall -Wno-unused-function -mtls-dialect=gnu $(INC) -include include/wmtr_glibc_compat.h
client-linux: $(OUT)/x86_64-linux/winemetal.so
$(OUT)/x86_64-linux/winemetal.so: src/wmtr_client.c src/transport_virtgpu.c include/*.h src/*.inc
	mkdir -p $(OUT)/x86_64-linux
	$(CC) $(LINUX_CFLAGS) -shared -fPIC -o $@ src/wmtr_client.c src/transport_virtgpu.c -lpthread -ldl
test-linux: $(OUT)/x86_64-linux/winemetal.so
	mkdir -p $(OUT)/x86_64-linux/standin
	$(CC) -shared -fPIC -o $(OUT)/x86_64-linux/standin/ntdll.so tests/ntdll_standin.c
	$(CC) -O2 -o $(OUT)/x86_64-linux/wmtr_ntdll_test tests/wmtr_ntdll_test.c -ldl
	./$(OUT)/x86_64-linux/wmtr_ntdll_test $(abspath $(OUT))/x86_64-linux/standin/ntdll.so $(abspath $(OUT))/x86_64-linux/winemetal.so
	@# loads in the Steam Runtime (sniper, glibc 2.31): no newer glibc version, no TLS-descriptor ABI requirement
	@if readelf -V $< | grep -E 'GLIBC_ABI_|GLIBC_2\.(3[2-9]|[4-9][0-9])'; then echo "FAIL: glibc requirement too new"; exit 1; fi
	@echo "glibc requirements: ok"

# guest payload for the steamac layer (scripts/steps/30-layer.sh): DXMT's PE dlls (DXMT_PE=, Wine builtins from
# DXMT's mingw build) and the Linux wmtr client (client-linux, built on an x86_64 Linux host)
DXMT_PE ?= ../work/out/dxmt-pe
PAYLOAD ?= ../work/out/dxmt
dxmt-payload:
	install -d $(PAYLOAD)/x86_64-windows $(PAYLOAD)/x86_64-unix
	for f in d3d11 dxgi d3d10core winemetal; do install -m 644 $(DXMT_PE)/$$f.dll $(PAYLOAD)/x86_64-windows/$$f.dll; done
	@# optional: DXMT's D3D12 (steam-gfx-path routes it over vkd3d-proton only when the payload has it)
	if [ -f $(DXMT_PE)/d3d12.dll ]; then install -m 644 $(DXMT_PE)/d3d12.dll $(PAYLOAD)/x86_64-windows/d3d12.dll; fi
	install -m 644 $(OUT)/x86_64-linux/winemetal.so $(PAYLOAD)/x86_64-unix/winemetal.so

# the launcher bundle picks the host library up from libkrun's prefix (host/launcher/bundle.sh)
PREFIX ?= ../work/out/host
install: $(OUT)/libwmtr_host.dylib
	install -d $(PREFIX)/lib
	@tmp=$$(mktemp "$(PREFIX)/lib/.libwmtr_host.XXXXXX"); \
	  install -m 755 $< "$$tmp" && mv -f "$$tmp" "$(PREFIX)/lib/libwmtr_host.dylib"

clean:
	rm -rf $(OUT)
.PHONY: all host client-linux test test-linux install dxmt-payload clean
