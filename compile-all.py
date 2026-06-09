import json, os, re

# ── Install & import py-solc-x ──
from py_solc_x import install_solc, compile_standard, set_solc_version

SOLC_VERSION = "0.8.20"
install_solc(SOLC_VERSION)
set_solc_version(SOLC_VERSION)

BASE = "../2026-06-07-22-33-14/squid-launch/contracts-simple"
OUT  = "../2026-06-07-22-33-14/squid-launch"

def compile_contract(file_name, contract_name):
    with open(os.path.join(BASE, file_name), "r", encoding="utf-8") as f:
        source = f.read()
    inp = {
        "language": "Solidity",
        "sources": {file_name: {"content": source}},
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "viaIR": True,
            "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object"]}}
        }
    }
    out = compile_standard(inp, solc_version=SOLC_VERSION)
    artifact = out["contracts"][file_name][contract_name]
    abi      = artifact["abi"]
    bytecode = artifact["evm"]["bytecode"]["object"]
    # write artifacts
    with open(os.path.join(OUT, f"{contract_name}_abi.json"),  "w") as f:
        json.dump(abi, f, indent=2)
    with open(os.path.join(OUT, f"{contract_name}_bytecode.txt"), "w") as f:
        f.write(bytecode)
    print(f"[OK] {contract_name}: bytecode {len(bytecode)} chars")
    return abi, bytecode

def gen_js(contract_name, abi, bytecode):
    var_name = "CONTRACT_DATA" if contract_name == "SimpleToken" else "DISTRIBUTOR_DATA"
    lines = []
    lines.append(f"var {var_name} = {{")
    lines.append("  ABI: " + json.dumps(abi, indent=2, separators=(',',': ')).replace('\n', '\n  '))
    lines.append(f",\n  BYTECODE: '0x{bytecode}'")
    lines.append("};")
    with open(os.path.join(OUT, f"{contract_name.lower()}_data.js"), "w") as f:
        f.write("\n".join(lines))
    print(f"[OK] {contract_name.lower()}_data.js written")

# ── Compile ──
abi1, bc1 = compile_contract("SimpleToken.sol",        "SimpleToken")
abi2, bc2 = compile_contract("DividendDistributor.sol", "DividendDistributor")

# ── Generate JS data files ──
gen_js("SimpleToken",        abi1, bc1)
gen_js("DividendDistributor", abi2, bc2)

print("\nDone — all artifacts & JS data files generated.")
