SRCPATH=../x264-source
prefix=/private/tmp/com.example.Resizer.ffmpeg-build/8.1.2-profile12/x264-prefix-x86_64
exec_prefix=${prefix}
bindir=${exec_prefix}/bin
libdir=${exec_prefix}/lib
includedir=${prefix}/include
SYS_ARCH=X86_64
SYS=MACOSX
CC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
CFLAGS=-Wshadow -O3 -ffast-math -m64  -Wall -I. -I$(SRCPATH) --sysroot=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -arch x86_64 -mmacosx-version-min=14.0 -ffile-prefix-map=/private/tmp/com.example.Resizer.ffmpeg-build/8.1.2-profile12=/usr/src/resizer-ffmpeg/8.1.2-profile12 -fdebug-prefix-map=/private/tmp/com.example.Resizer.ffmpeg-build/8.1.2-profile12=/usr/src/resizer-ffmpeg/8.1.2-profile12 -fmacro-prefix-map=/private/tmp/com.example.Resizer.ffmpeg-build/8.1.2-profile12=/usr/src/resizer-ffmpeg/8.1.2-profile12 -arch x86_64 -std=gnu99 -D_GNU_SOURCE -mstack-alignment=64 -fPIC -fomit-frame-pointer -fno-tree-vectorize -fvisibility=hidden
CFLAGSSO=
CFLAGSCLI=
COMPILER=GNU
COMPILER_STYLE=GNU
DEPCMD=
DEPFLAGS=-MMD -MF $(@:.o=.d)
LD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -o 
LDFLAGS=-m64  --sysroot=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -arch x86_64 -mmacosx-version-min=14.0 -lm -arch x86_64 -lpthread
LDFLAGSCLI=
LIBX264=libx264.a
CLI_LIBX264=$(LIBX264)
AR=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar rc 
RANLIB=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ranlib
STRIP=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/strip
INSTALL=install
AS=
ASFLAGS= -I. -I$(SRCPATH) --sysroot=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -arch x86_64 -mmacosx-version-min=14.0 -DARCH_X86_64=1 -I$(SRCPATH)/common/x86/ -f macho64 -DPREFIX -DSTACK_ALIGNMENT=64 -DPIC
RC=
RCFLAGS=
EXE=
HAVE_GETOPT_LONG=1
DEVNULL=/dev/null
PROF_GEN_CC=-fprofile-generate
PROF_GEN_LD=-fprofile-generate
PROF_USE_CC=-fprofile-use
PROF_USE_LD=-fprofile-use
HAVE_OPENCL=no
CC_O=-o $@
default: lib-static
install: install-lib-static
