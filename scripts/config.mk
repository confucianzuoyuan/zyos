#----------------------------------------------------------------------------
# config.mk
# MonkOS makefile shared configuration settings
#
# The following variables should be set before including this file:
#
#   DIR_ROOT	The root directory of the project.
#
#----------------------------------------------------------------------------

#--------------------
# Project directories
#--------------------
DIR_BOOT	:= $(DIR_ROOT)/boot
DIR_BUILD	:= $(DIR_ROOT)/build
DIR_DEPS	:= $(DIR_ROOT)/deps
DIR_DOCKER 	:= $(DIR_ROOT)/docker
DIR_DOCS	:= $(DIR_ROOT)/docs
DIR_INCLUDE	:= $(DIR_ROOT)/include
DIR_KERNEL	:= $(DIR_ROOT)/kernel
DIR_LIBC	:= $(DIR_ROOT)/libc
DIR_SCRIPTS	:= $(DIR_ROOT)/scripts


#-------------------
# Tool configuration
#-------------------
TARGET		:= x86_64-elf

CC		:= $(TARGET)-gcc

CCFLAGS		:= -std=gnu11 -I$(DIR_INCLUDE) -Qn -g \
		   -m64 -mno-red-zone -mno-mmx -mfpmath=sse -masm=intel \
		   -ffreestanding -fno-asynchronous-unwind-tables \
		   -Wall -Wextra -Wpedantic

AS		:= nasm

ASFLAGS		:= -f elf64

AR		:= $(TARGET)-ar

LDFLAGS		:= -g -nostdlib -m64 -mno-red-zone -ffreestanding -lgcc \
		   -z max-page-size=0x1000

CTAGS		:= ctags

DOXYGEN		:= doxygen

MAKE_FLAGS	:= --quiet --no-print-directory

QEMU		:= qemu-system-x86_64

UNCRUSTIFY	:= uncrustify

UNCRUSTIFY_CFG	:= $(DIR_SCRIPTS)/uncrustify.cfg


#---------------------
# Display color macros
#---------------------
BLUE		:= \033[1;34m
YELLOW		:= \033[1;33m
NORMAL		:= \033[0m

SUCCESS		:= $(YELLOW)SUCCESS$(NORMAL)
