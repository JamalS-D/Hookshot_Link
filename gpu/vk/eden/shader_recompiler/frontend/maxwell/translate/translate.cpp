// SPDX-FileCopyrightText: Copyright 2025 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

// SPDX-FileCopyrightText: Copyright 2021 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "shader_recompiler/environment.h"
#include "shader_recompiler/frontend/ir/basic_block.h"
#include "shader_recompiler/frontend/maxwell/decode.h"
#include "shader_recompiler/frontend/maxwell/location.h"
#include "shader_recompiler/frontend/maxwell/translate/impl/impl.h"
#include "shader_recompiler/frontend/maxwell/translate/translate.h"

namespace Shader::Maxwell {

void Translate(Environment& env, IR::Block* block, u32 location_begin, u32 location_end) {
    if (location_begin != location_end) {
        TranslatorVisitor visitor{env, *block};
        for (Location pc = location_begin; pc != location_end; ++pc) {
            u64 const insn = env.ReadInstruction(pc.Offset());
            Opcode const opcode = Decode(insn);
            // (hookshot) Accumulate REGMAP_nx2 prefixes forward in-place; only scan backwards at block
            // entry in case a basic-block split landed between a prefix and its instruction.
            if (opcode == Opcode::REGMAP_nx2) {
                visitor.ApplyRegisterMap(insn);
                continue;
            }
            if (pc == location_begin && !visitor.has_register_map) {
                Location prev{pc};
                for (int guard = 0; guard < 8 && prev.Offset() >= 16; ++guard) {
                    --prev;
                    const u64 before{env.ReadInstruction(prev.Offset())};
                    if ((before >> 51) != (0xefe0ULL >> 3)) {
                        break;
                    }
                    visitor.ApplyRegisterMap(before);
                }
            }
            switch (opcode) {
#define INST(name, cute, mask) case Opcode::name: visitor.name(insn); break;
#include "shader_recompiler/frontend/maxwell/maxwell.inc"
#undef OPCODE
            }
            if (visitor.has_register_map) {
                visitor.register_map.fill(0);
                visitor.has_register_map = false;
            }
        }
    }
}

} // namespace Shader::Maxwell
