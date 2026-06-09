const solc = require('solc');
const fs = require('fs');
const path = require('path');

const srcPath = path.join(__dirname, 'contracts-simple', 'SimpleToken.sol');
const source = fs.readFileSync(srcPath, 'utf8');

const input = {
    language: 'Solidity',
    sources: { 'SimpleToken.sol': { content: source } },
    settings: {
        outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
        optimizer: { enabled: true, runs: 200 },
        viaIR: true,
        evmVersion: 'paris'
    }
};

const output = JSON.parse(solc.compile(JSON.stringify(input)));

if (output.errors) {
    for (const e of output.errors) {
        if (e.severity === 'error') console.error('ERROR:', e.formattedMessage);
    }
    const hasErrors = output.errors.some(e => e.severity === 'error');
    if (hasErrors) process.exit(1);
}

const contract = output.contracts['SimpleToken.sol']['SimpleToken'];
const bytecode = '0x' + contract.evm.bytecode.object;
const abi = JSON.stringify(contract.abi);

fs.writeFileSync(path.join(__dirname, 'bytecode.txt'), bytecode);
fs.writeFileSync(path.join(__dirname, 'abi.json'), abi);

console.log('COMPILED OK');
console.log('Bytecode length:', bytecode.length);
console.log('ABI length:', abi.length);
