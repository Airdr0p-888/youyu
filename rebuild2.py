import json, re

with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/SimpleToken_bytecode.txt', 'r') as f:
    bytecode = f.read().strip()
with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/SimpleToken_abi.json', 'r') as f:
    abi_json = f.read().strip()
with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/launch.html', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace bytecode
content = re.sub(
    r'const TOKEN_BYTECODE\s*=\s*[\'"].*?[\'"];',
    f'const TOKEN_BYTECODE = \'{bytecode}\';',
    content, flags=re.DOTALL
)
# Replace ABI
content = re.sub(
    r'const TOKEN_ABI\s*=\s*\[.*?\];',
    f'const TOKEN_ABI = {abi_json};',
    content, flags=re.DOTALL
)

# Replace doLaunch()
NEW_DOLAUNCH = r'''async function doLaunch(){
  var btn = document.getElementById('launchBtn');
  if(!window.ethereum){ alert('请安装 MetaMask'); return; }

  var name      = document.getElementById('t_name').value.trim();
  var sym       = document.getElementById('t_symbol').value.trim().toUpperCase();
  var supply    = document.getElementById('t_supply').value.trim();
  var mintPrice = document.getElementById('t_mintPrice').value.trim();
  var hardCap   = document.getElementById('t_hardCap').value.trim();
  if(!name || !sym || !supply || !mintPrice || !hardCap){ alert('请填写代币名称、符号、供应量、铸造价格、硬顶'); return; }

  btn.textContent = '准备部署...'; btn.disabled = true;
  try {
    var web3 = new Web3(window.ethereum);
    var acc = await ethereum.request({method:'eth_requestAccounts'});
    var userAddr = acc[0];

    var presalePct   = +(document.getElementById('t_presaleRatio')?.value) || 0;
    var liqPct       = +(document.getElementById('t_liqPct')?.value) || 0;
    var buyTaxBps    = Math.round(parseFloat(document.getElementById('buyTaxSlider').value) * 100);
    var sellTaxBps   = Math.round(parseFloat(document.getElementById('sellTaxSlider').value) * 100);
    var maxTxPct     = +(document.getElementById('t_maxTx')?.value) || 0;
    var maxWalletPct = +(document.getElementById('t_maxWallet')?.value) || 0;

    var supplyWei    = web3.utils.toWei(supply,    'ether');  // 1 token = 1e18
    var mintPriceWei = web3.utils.toWei(mintPrice, 'ether');
    var hardCapWei   = web3.utils.toWei(hardCap,   'ether');

    // Open mode config
    var openModeNum = currentOpenMode === 'auto' ? 0 : currentOpenMode === 'manual' ? 1 : 2;
    var openTimeTs  = 0;
    var fullOpenDelay = 0;
    if (openModeNum === 0) {
      var openTimeVal = document.getElementById('t_openTime')?.value;
      if (openTimeVal) openTimeTs = Math.floor(new Date(openTimeVal).getTime() / 1000);
    } else if (openModeNum === 2) {
      var delayVal = document.getElementById('t_fullOpenDelay')?.value;
      fullOpenDelay = delayVal ? parseInt(delayVal) * 60 : 300;
    }

    var tc = [name, sym, supplyWei, mintPriceWei, hardCapWei,
              String(presalePct), openModeNum, String(openTimeTs), String(fullOpenDelay)];
    var fc = [String(liqPct), String(buyTaxBps), String(sellTaxBps),
              String(maxTxPct), String(maxWalletPct)];

    // Deploy (1 tx = everything configured)
    btn.textContent = '部署代币合约...';
    var tcContract = new web3.eth.Contract(TOKEN_ABI);
    var depTx = tcContract.deploy({
      data: TOKEN_BYTECODE,
      arguments: [userAddr, PLATFORM_WALLET, PANCAKE_ROUTER, tc, fc]
    });

    var gas = await depTx.estimateGas({ from: userAddr });
    btn.textContent = '请在钱包中确认交易...';
    var dep = await depTx.send({
      from: userAddr,
      gas: Math.floor(gas * 1.2),
      gasPrice: web3.utils.toWei('3', 'gwei')
    });
    var tokenAddr = dep.options.address;
    console.log('Token deployed:', tokenAddr);

    // Show result
    document.getElementById('deployResult').style.display = 'block';
    document.getElementById('contractAddr').textContent = tokenAddr;

    var modeText = openModeNum === 0 ? '定时开盘（' + (document.getElementById('t_openTime')?.value || '未设置') + '）' :
      openModeNum === 1 ? '手动开盘（部署后需调用 enableTrading）' :
      '满额开盘（硬顶达 ' + hardCap + ' BNB 后自动开）';
    document.getElementById('resultOpenMode').textContent = modeText;

    document.getElementById('constructorArgs').innerHTML =
      '<code style="font-size:0.72rem;line-height:1.8;word-break:break-all;display:block;color:var(--text2)">' +
      'Token: ' + tokenAddr + '<br>' +
      'Owner: ' + userAddr + '<br>' +
      'Platform: ' + PLATFORM_WALLET + '<br>' +
      'OpenMode: ' + ['定时','手动','满额'][openModeNum] + '<br>' +
      'MintPrice: ' + mintPrice + ' BNB / token<br>' +
      'HardCap: ' + hardCap + ' BNB' +
      '</code>';
    document.getElementById('deployResult').scrollIntoView({behavior:'smooth'});
    btn.textContent = '部署成功 ✓';
  } catch(e) {
    console.error(e);
    var msg = e.message || String(e);
    if(msg.indexOf('user rejected') >= 0) msg = '用户在钱包中取消';
    if(msg.indexOf('insufficient funds') >= 0) msg = '余额不足';
    if(msg.indexOf('WETH fail') >= 0) msg = 'Router WETH 调用失败（地址或网络不对）';
    if(msg.indexOf('factory fail') >= 0) msg = 'Router factory() 调用失败';
    if(msg.indexOf('createPair fail') >= 0) msg = 'PancakeSwap 创建交易对失败';
    if(msg.indexOf('price=0') >= 0) msg = '铸造价格不能为 0';
    if(msg.indexOf('supply=0') >= 0) msg = '供应量不能为 0';
    if(msg.indexOf('presale>100') >= 0) msg = '预售占比不能超过 100%';
    if(msg.indexOf('liqPct>100') >= 0) msg = '流动性占比不能超过 100%';
    if(msg.indexOf('bad mode') >= 0) msg = '开盘模式参数错误';
    if(msg.indexOf('limit>100') >= 0) msg = '交易限制不能超过 100%';
    if(msg.indexOf('tax high') >= 0) msg = '税费不能超过 25%';
    alert('部署失败：' + msg);
    btn.textContent = '立即发射代币'; btn.disabled = false;
  }
}'''

# Find the doLaunch function and replace everything from `async function doLaunch()` to the closing `}` before the next top-level function
# Use a more robust regex: find `async function doLaunch()` and replace until we hit the next `function` at the same level
start_idx = content.index('async function doLaunch()')
# Find the matching closing brace by counting braces
brace_depth = 0
end_idx = start_idx
in_string = False
string_char = ''
for i in range(start_idx, len(content)):
    c = content[i]
    if in_string:
        if c == string_char and content[i-1] != '\\':
            in_string = False
        continue
    if c == '"' or c == "'" or c == '`':
        in_string = True
        string_char = c
        continue
    if c == '{':
        brace_depth += 1
    elif c == '}':
        brace_depth -= 1
        if brace_depth == 0:
            end_idx = i + 1
            break

new_content = content[:start_idx] + NEW_DOLAUNCH + '\n\n' + content[end_idx:]

with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/launch.html', 'w', encoding='utf-8') as f:
    f.write(new_content)

print(f'Replaced doLaunch. File: {len(new_content)} bytes. Old: {len(content)} bytes.')

# Verify
with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/launch.html', 'r', encoding='utf-8') as f:
    check = f.read()

# Check
assert 'const TOKEN_BYTECODE' in check
assert 'const TOKEN_ABI' in check
assert 'async function doLaunch()' in check
assert 'setOpenConfig' not in check, 'setOpenConfig still present!'
assert 'arguments: [userAddr, PLATFORM_WALLET, PANCAKE_ROUTER, tc, fc]' in check
print('All checks passed!')
