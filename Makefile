include config.mk

# rebuild when makefile changes
-include dummy.rebuild

.PHONY: all clean libpfc libpfc-clean

CXX ?= g++
CC ?= gcc
ASM ?= nasm
ASM_FLAGS ?= -DNASM_ENABLE_DEBUG=$(NASM_DEBUG) -w+all -l x86_methods.list

# The target to build when building libpfc (if we build it at all). By default, we are going
# to build everything, but TravisCI, for example, would (usually) like to skip building the kernel module. 
LIBPFC_TARGET ?= all

PFM_DIR ?= libpfm4
PFM_LIBDIR ?= $(PFM_DIR)/lib

PSNIP_DIR ?= portable-snippets
# all the psnip source files we want to compile into uarch-bench
PSNIP_SRC := cpu.c

GIT_VERSION := $(shell git describe --dirty --always)

ifneq ($(CPU_ARCH),)
ARCH_FLAGS := -march=$(CPU_ARCH)
endif
O_LEVEL ?= -O2

COMMON_FLAGS := -MMD -Wall $(ARCH_FLAGS) -g $(O_LEVEL) -DGIT_VERSION=\"$(GIT_VERSION)\" -DUSE_LIBPFC=$(USE_LIBPFC) \
-DUSE_BACKWARD_CPP=$(USE_BACKWARD_CPP) -DBACKWARD_HAS_BFD=$(BACKWARD_HAS_BFD) -DBACKWARD_HAS_DW=$(BACKWARD_HAS_DW) -I$(PSNIP_DIR)
CPPFLAGS := $(COMMON_FLAGS)
CFLAGS := $(COMMON_FLAGS)

# files that should only be compiled if USE_LIBPFC is enabled
PFC_SRC := libpfc-timer.cpp libpfm4-support.cpp
SRC_FILES := $(wildcard *.cpp) $(wildcard *.c) nasm-utils/nasm-utils-helper.c $(PSNIP_SRC)
SRC_FILES := $(filter-out $(PFC_SRC), $(SRC_FILES))

# on most compilers we should use no-pie since the nasm stuff isn't position independent
# but since old compilers don't support it, you can override it with PIE= on the command line
PIE ?= -no-pie
LDFLAGS += $(PIE)

ifeq ($(USE_LIBPFC),1)
LDFLAGS += -Llibpfc '-Wl,-rpath=$$ORIGIN/libpfc/' -L$(PFM_LIBDIR) '-Wl,-rpath=$$ORIGIN/$(PFM_LIBDIR)/'
LDLIBS += -lpfc -lpfm
LIBPFC_DEP += libpfc/libpfc.so libpfc/pfc.ko $(PFM_LIBDIR)/libpfm.so
CLEAN_TARGETS += libpfc-clean libpfm4-clean
SRC_FILES += $(PFC_SRC)
endif

ifeq ($(BACKWARD_HAS_BFD),1)
LDFLAGS += -lbfd -ldl
endif

ifeq ($(BACKWARD_HAS_DW),1)
LDFLAGS += -ldw
endif

OBJECTS := $(SRC_FILES:.cpp=.o) x86_methods.o x86_methods2.o
OBJECTS := $(OBJECTS:.c=.o)
DEPFILES = $(OBJECTS:.o=.d)
# $(info OBJECTS=$(OBJECTS))

$(info USE_LIBPFC=${USE_LIBPFC})

VPATH = test:$(PSNIP_DIR)/cpu

###########
# Targets #
###########

all: uarch-bench unit-test

-include $(DEPFILES) unit-test.d

clean:	libpfc-clean
	rm -f *.d *.o uarch-bench

dist-clean: clean $(CLEAN_TARGETS)

# $(filter-out $(OBJECTS), main.o)

# link all object files except main.o into unit-test
UNIT_OBJECTS := $(filter-out main.o, $(OBJECTS)) 
unit-test: unit-test.o unit-test-main.o $(UNIT_OBJECTS) 
	$(CXX) $^         $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) $(LDLIBS) -std=c++11 -o $@

uarch-bench: $(OBJECTS) $(LIBPFC_DEP)
	$(CXX) $(OBJECTS) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) $(LDLIBS) -std=c++11 -o $@
# the next two lines are only to print out the size of the binary for diagnostic purposes, feel free to omit them
	@wc -c uarch-bench | awk '{print "binary size: " $$1/1000 "KB"}'
	@size uarch-bench --format=SysV | egrep '\.text|\.eh_frame|\.rodata|^section'

%.o : %.c $(LIBPFC_DEP)
	$(CC) $(CFLAGS) -c -std=c11 -o $@ $<

%.o : %.cpp $(LIBPFC_DEP)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c -std=c++11 -o $@ $<

%.o: %.asm nasm-utils/nasm-utils-inc.asm
	$(ASM) $(ASM_FLAGS) ${NASM_DEFINES} -f elf64 $<

# fake dependency, but prevents make from trying to build libpfc twice in parallel if both the ko and so are missing
libpfc/pfc.ko: libpfc/libpfc.so

libpfc/libpfc.so libpfc/pfc.ko:
	@echo "Buiding libpfc target $(LIBPFC_TARGET)"
	cd libpfc && make $(LIBPFC_TARGET)

libpfc-clean:
	cd libpfc && make clean

insmod: libpfc
	sudo sh -c "echo 2 > /sys/bus/event_source/devices/cpu/rdpmc"
	! lsmod | grep -q pfc || sudo rmmod pfc
	sudo insmod libpfc/pfc.ko

$(PFM_LIBDIR)/libpfm.so:
	$(MAKE) -C $(PFM_DIR) lib

libpfm4-clean:
	$(MAKE) -C $(PFM_DIR) clean
	
LOCAL_MK = $(wildcard local.mk)
	
# https://stackoverflow.com/a/3892826/149138
dummy.rebuild: Makefile config.mk $(LOCAL_MK)
	touch $@
	$(MAKE) -s clean
