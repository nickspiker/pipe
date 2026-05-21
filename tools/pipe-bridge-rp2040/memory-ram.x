/* Dev image layout — built with `cargo build --features ram-image`, loaded into SRAM by `picotool load --execute` for hot iteration. FLASH aliased to the low 176 KB of SRAM (0x20000000-0x2002C000) so cortex-m-rt places .text/.rodata/.data there; RAM is the top 80 KB (0x2002C000-0x20040000) for .bss/stack/heap. picotool reads load addresses from the ELF program headers, parks the binary at these exact addresses, then jumps to the reset handler. */
MEMORY {
    FLASH : ORIGIN = 0x20000000, LENGTH = 176K
    RAM   : ORIGIN = 0x2002C000, LENGTH = 80K
}
