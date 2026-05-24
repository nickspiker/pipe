/* Dev image layout — built with `cargo build --features ram-image`, streamed into
 * SRAM by the manager firmware via `bridge load_dev`. Text + .rodata + .data init
 * live in the low 176 KB of SRAM (0x20000000-0x2002C000); .bss / heap / stack live
 * in the top 88 KB (0x2002C000-0x20042000), matching the manager's own RAM region
 * so both builds have identical RAM layout — the dev image just takes over manager's
 * SRAM after the handoff. Picotool/UF2 paths are no longer used; the manager does
 * the load. */
MEMORY {
    FLASH : ORIGIN = 0x20000000, LENGTH = 176K
    RAM   : ORIGIN = 0x2002C000, LENGTH = 88K
}
