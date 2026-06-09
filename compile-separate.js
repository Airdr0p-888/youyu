const solc = require("solc");
const fs   = require("fs");
const path = require("path");

const contractFile = process.argv[2] || "contracts-simple/DividendDistributor.sol";
const contractName = process.argv[3] || "DividendDistributor";

const source = fs.readFileSync(contractFile, "utf8");

const input = {
  language: "Solidity",
  sources: { [contractFile]: { content: source } },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    viaIR: true,
    outputSelection: { "*": { "*": ["abi","evm.bytecode.object"] } }
  }
};

const output = JSON.parse(solc.compile(JSON.stringify(input)));

if (output.errors) {
  const errs = output.errors.filter(e => e.severity === "error");
  if (errs.length) { console.error(JSON.stringify(errs, null, 2)); process.exit(1); }
  output.errors.forEach(e => console.warn(e.formattedMessage || e.message));
}

const artifact = output.contracts[contractFile][contractName];
fs.writeFileSync(contractName + "_bytecode.txt", artifact.evm.bytecode.object);
fs.writeFileSync(contractName + "_abi.json", JSON.stringify(artifact.abi, null, 2));
console.log(contractName + " — OK，bytecode " + artifact.evm.bytecode.object.length + " chars");
