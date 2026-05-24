/* RAM split for in-firmware hot-reload over CDC/VSF.
 * - Manager (this build): RAM at 0x2002C000 length 88K — the top of SRAM. While the
 *   manager streams a dev image into 0x20000000..0x2002C000, manager's own .bss/.data/
 *   stack live entirely above 0x2002C000 so the in-flight write doesn't trample them.
 * - Dev image (ram-image build, memory-ram.x): text 0x20000000 length 176K, RAM
 *   0x2002C000 length 80K. Once the manager jumps, manager is dead and the dev image
 *   owns all of SRAM (overlapping the old manager RAM is fine — manager is gone).
 */
MEMORY {
    BOOT2 : ORIGIN = 0x10000000, LENGTH = 0x100
    FLASH : ORIGIN = 0x10000100, LENGTH = 2048K - 0x100
    RAM   : ORIGIN = 0x2002C000, LENGTH = 88K
}

EXTERN(BOOT2_FIRMWARE)

SECTIONS {
    .boot2 ORIGIN(BOOT2) : {
        KEEP(*(.boot2));
    } > BOOT2
} INSERT BEFORE .text;
