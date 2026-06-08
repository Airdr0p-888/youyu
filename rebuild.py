#!/usr/bin/env python3
"""Rebuild launch.html from backup + compiled artifacts."""

# Read backup
with open('F:/动态图片/launch.html', 'r', encoding='utf-8') as f:
    html = f.read()

# Read compiled artifacts
with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/SimpleToken_bytecode.txt', 'r') as f:
    bytecode = f.read().strip()

with open('C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/SimpleToken_abi.json', 'r') as f:
    abi_json = f.read().strip()

# Find the script block
script_start = html.index('<script>')

# Build the new JS section
NEW_JS = '''<script>

const PLATFORM_WALLET = '0x8fdb0a964beda0da705d2fe5af2fb9a7001cbb36';
const PANCAKE_ROUTER  = '0x10ed43c718714eb63d5aa57b78b5c4bf50ebf4e7';
const TOKEN_BYTECODE = '__BYTECODE__';
const TOKEN_ABI = __ABI__;

async function connectWallet(){
  if(!window.ethereum){
    alert('未检测到钱包插件，请安装 MetaMask 或 TP Wallet');
    return;
  }
  try {
    const accounts = await ethereum.request({ method: 'eth_requestAccounts' });
    const addr = accounts[0];
    onWalletConnected(addr);
  } catch(e){
    console.error('连接钱包失败', e);
    alert('连接钱包失败：' + (e.message || e));
  }
}

function onWalletConnected(addr){
  const box = document.getElementById('wallet-box');
  box.className = 'wallet-bar wb-conn';
  const shortAddr = addr.slice(0,6) + '...' + addr.slice(-4);
  box.innerHTML =
    '<span class="wd wd-g"></span>' +
    '<span style="flex:1;font-size:0.86rem">已连接：' + shortAddr + ' (BSC)</span>' +
    '<button class="btn btn-outline btn-sm" onclick="disconnectWallet()">断开</button>';

  document.getElementById('launchBtn').disabled = false;
  const steps = document.querySelectorAll('.sb-step');
  steps[0].classList.add('done'); steps[0].classList.remove('active');
  if(steps[1]) steps[1].classList.add('active');

  checkPlatformWallet(addr);
}

function checkPlatformWallet(addr){
  const isPlatform = (addr.toLowerCase() === PLATFORM_WALLET);
  const mfr = document.getElementById('mintFundRule');
  if(mfr) mfr.style.display = isPlatform ? '' : 'none';
}

(async function autoConnect(){
  // Set default open time = 24h later
  const defTime = new Date(Date.now() + 24*3600000);
  const pad2 = n => String(n).padStart(2,'0');
  const timeInput = document.getElementById('t_openTime');
  if(timeInput) {
    timeInput.value =
      defTime.getFullYear() + '-' + pad2(defTime.getMonth()+1) + '-' + pad2(defTime.getDate()) + 'T' +
      pad2(defTime.getHours()) + ':' + pad2(defTime.getMinutes());
    onOpenTimeChange();
  }

  // Initialize open mode UI
  if(document.getElementById('optAuto')) selectOpenMode('auto');

  if(window.ethereum && ethereum.selectedAddress){
    onWalletConnected(ethereum.selectedAddress);
  }
  if(window.ethereum){
    ethereum.on('accountsChanged', (accounts) => {
      if(accounts.length > 0){
        onWalletConnected(accounts[0]);
      } else {
        disconnectWallet();
      }
    });
  }
})();

function disconnectWallet(){
  location.reload();
}

function onOpenTimeChange(){
  const val = document.getElementById('t_openTime').value;
  const hint = document.getElementById('openTimeHint');
  if(!val){
    hint.textContent = '选择时间后，到达该时刻合约将自动完成预售并开启交易';
    hint.style.color = '';
    return;
  }
  const d = new Date(val);
  const now = Date.now();
  const diffMs = d.getTime() - now;
  if(diffMs <= 0){
    hint.textContent = '⚠️ 开盘时间必须晚于当前时间';
    hint.style.color = '#ff4757';
  } else {
    const hours = Math.floor(diffMs / 3600000);
    const mins = Math.floor((diffMs % 3600000) / 60000);
    if(hours > 48){
      hint.textContent = d.toLocaleString() + '（距现在 ' + hours + ' 小时）';
      hint.style.color = '';
    } else {
      hint.textContent = d.toLocaleString() + '（约 ' + hours + 'h' + mins + 'm 后开盘）';
      hint.style.color = '';
    }
  }
}

let currentOpenMode = 'auto';
function selectOpenMode(mode){
  currentOpenMode = mode;

  const optAuto = document.getElementById('optAuto');
  const optManual = document.getElementById('optManual');
  const optFull = document.getElementById('optFull');
  if(optAuto) optAuto.classList.toggle('selected', mode === 'auto');
  if(optManual) optManual.classList.toggle('selected', mode === 'manual');
  if(optFull) optFull.classList.toggle('selected', mode === 'full');

  const stb = document.getElementById('scheduledTimeBox');
  const fodb = document.getElementById('fullOpenDelayBox');
  if(stb) stb.style.display = (mode === 'auto') ? '' : 'none';
  if(fodb) fodb.style.display  = (mode === 'full') ? '' : 'none';

  const radio = document.querySelector('input[name="openMode"][value="' + mode + '"]');
  if(radio) radio.checked = true;
}

function formatTokenPrice(v){
  if(!v) return '0';
  if(v >= 0.0001) return v.toFixed(8).replace(/0+$/,'').replace(/\.$/,'');
  const s = v.toExponential();
  const parts = s.split('e');
  const mantissa = parts[0];
  const exp = parseInt(parts[1]);
  if(exp >= 0) return v.toFixed(8);
  const digits = mantissa.replace('.','').replace(/^0+/g,'') || '0';
  return '0.' + '0'.repeat(-exp - 1) + digits;
}

function calcPreview(){
  const supply   = parseFloat(document.getElementById('t_supply').value)    || 0;
  const price    = parseFloat(document.getElementById('t_mintPrice').value)  || 0;
  const hardCap  = parseFloat(document.getElementById('t_hardCap').value)    || 0;
  const ratio    = parseFloat(document.getElementById('t_presaleRatio').value)||0;
  const lpDisplay = document.getElementById('lpRatioDisplay');
  if(lpDisplay) lpDisplay.textContent = (100 - ratio) + '%';
  const mintCount = price > 0 && hardCap > 0 ? Math.floor(hardCap / price) : 0;
  const perMint   = supply > 0 && ratio > 0 && mintCount > 0 ? Math.floor((supply * ratio / 100) / mintCount) : 0;
  const unitPrice = perMint > 0 && price > 0 ? formatTokenPrice(price / perMint) : '—';
  const cmc = document.getElementById('calcMintCount');
  const cpm = document.getElementById('calcPerMint');
  const cup = document.getElementById('calcUnitPrice');
  if(cmc) cmc.textContent = mintCount ? mintCount.toLocaleString() : '—';
  if(cpm) cpm.textContent   = perMint  ? perMint.toLocaleString()   : '—';
  if(cup) cup.textContent = unitPrice;

  const divPct   = parseFloat(document.getElementById('t_dividendPct').value) || 0;
  const divAbs   = supply > 0 && divPct > 0 ? Math.floor(supply * divPct / 100) : 0;
  const divAbsEl = document.getElementById('t_dividendAbs');
  if(divAbsEl){
    if(divAbs > 0){
      divAbsEl.textContent = Number(divAbs).toLocaleString('fullwide', {maximumFractionDigits: 0});
      divAbsEl.style.color = 'var(--cyan)';
    } else {
      divAbsEl.textContent = '—';
    }
  }
}

function updateDist(changedId){
  const ids = ['distWallet','distBurn','distReward','distLiq'];
  const valIds = ['distWalletVal','distBurnVal','distRewardVal','distLiqVal'];

  const current = {};
  ids.forEach(id => { current[id] = +document.getElementById(id).value; });

  if(changedId){
    const others = ids.filter(id => id !== changedId);
    const otherSum = others.reduce((s, id) => s + current[id], 0);
    const maxVal = Math.max(0, 100 - otherSum);
    if(current[changedId] > maxVal){
      current[changedId] = maxVal;
      document.getElementById(changedId).value = maxVal;
    }
  }

  ids.forEach((id, i) => {
    document.getElementById(valIds[i]).textContent = current[id] + '%';
  });

  const total = ids.reduce((s, id) => s + current[id], 0);
  const remain = 100 - total;
  document.getElementById('distTotal').innerHTML =
    '总计 ' + total + '% &nbsp; 未分配: <span class="' + (remain === 0 ? 'dt-ok' : 'dt-warn') + '">' + remain + '%</span>';

  const divCfg = document.getElementById('dividendConfig');
  if(divCfg){
    if(current['distReward'] > 0){
      divCfg.style.display = '';
    } else {
      divCfg.style.display = 'none';
    }
  }
}

async function doLaunch(){
  var btn = document.getElementById('launchBtn');
  if(!window.ethereum){ alert('请安装 MetaMask'); return; }

  var name    = document.getElementById('t_name').value.trim();
  var sym     = document.getElementById('t_symbol').value.trim().toUpperCase();
  var supply  = document.getElementById('t_supply').value.trim();
  var liqPct  = +(document.getElementById('t_liqPct')?.value) || 0;
  var liqBNB  = (document.getElementById('t_liqBNB')?.value || '').trim();

  if(!name || !sym || !supply){ alert('请填写代币名称、符号、供应量'); return; }

  btn.textContent = '准备部署...'; btn.disabled = true;
  try {
    var web3 = new Web3(window.ethereum);
    var acc = await ethereum.request({method:'eth_requestAccounts'});
    var userAddr = acc[0];

    var buyTaxBps  = Math.round(parseFloat(document.getElementById('buyTaxSlider').value) * 100);
    var sellTaxBps = Math.round(parseFloat(document.getElementById('sellTaxSlider').value) * 100);
    var maxTxPct     = +(document.getElementById('t_maxTx')?.value) || 0;
    var maxWalletPct = +(document.getElementById('t_maxWallet')?.value) || 0;

    // 1. Deploy SimpleToken (payable)
    btn.textContent = '部署代币合约...';
    var tc = new web3.eth.Contract(TOKEN_ABI);
    var depValue = (liqBNB && parseFloat(liqBNB) > 0) ? web3.utils.toWei(liqBNB, 'ether') : '0';
    var depTx = tc.deploy({
      data: TOKEN_BYTECODE,
      arguments: [name, sym, supply, userAddr, PLATFORM_WALLET, PANCAKE_ROUTER,
                  String(buyTaxBps), String(sellTaxBps), String(maxTxPct), String(maxWalletPct), String(liqPct)]
    });

    var gas = await depTx.estimateGas({ from: userAddr, value: depValue });
    btn.textContent = '请在钱包中确认交易...';
    var dep = await depTx.send({
      from: userAddr, gas: Math.floor(gas * 1.2),
      gasPrice: web3.utils.toWei('3', 'gwei'), value: depValue
    });
    var tokenAddr = dep.options.address;
    console.log('Token:', tokenAddr);

    // 2. Show result
    document.getElementById('deployResult').style.display = 'block';
    document.getElementById('contractAddr').textContent = tokenAddr;

    var modeText = currentOpenMode === 'auto' ? '定时开盘（' + (document.getElementById('t_openTime')?.value || '未设置') + '）' :
      currentOpenMode === 'manual' ? '手动开盘（需 Owner 调用 enableTrading）' :
      '满额开盘（达 Hard Cap 后 ' + (document.getElementById('t_fullOpenDelay')?.value || '5') + ' 分钟自动开）';
    document.getElementById('resultOpenMode').textContent = modeText;

    var divRow = document.getElementById('dividendAddrRow');
    if(divRow) divRow.style.display = 'none';

    document.getElementById('constructorArgs').innerHTML =
      '<code style="font-size:0.72rem;line-height:1.8;word-break:break-all;display:block;color:var(--text2)">' +
      'Token: ' + tokenAddr + '<br>' +
      'Owner: ' + userAddr + '<br>' +
      'Platform: ' + PLATFORM_WALLET + '<br>' +
      'Open: ' + currentOpenMode + '<br>' +
      'Liquidity: ' + (liqBNB || '0') + ' BNB / ' + liqPct + '%' +
      '</code>';
    document.getElementById('deployResult').scrollIntoView({behavior:'smooth'});
    btn.textContent = '部署成功 ✓';
  } catch(e) {
    console.error(e);
    var msg = e.message || String(e);
    if(msg.indexOf('user rejected') >= 0) msg = '用户在钱包中取消';
    if(msg.indexOf('insufficient funds') >= 0) msg = '余额不足';
    alert('部署失败：' + msg);
    btn.textContent = '立即发射代币'; btn.disabled = false;
  }
}


document.getElementById('fileInput')?.addEventListener('change', function(){
  if(this.files[0]){
    document.getElementById('uploadArea').innerHTML = '<span class="up-icon">✅</span><p>图片已上传 ✓</p><p class="small">点击更换</p>';
  }
});

window.addEventListener('scroll', ()=>{
  document.getElementById('navbar').style.borderBottomColor = window.scrollY > 10 ? 'rgba(0,200,255,0.15)' : 'rgba(0,200,255,0.1)';
});

calcPreview();
</script>'''

# Inject bytecode and ABI
NEW_JS = NEW_JS.replace('__BYTECODE__', bytecode)
NEW_JS = NEW_JS.replace('__ABI__', abi_json)

# Replace the script block (everything from <script> to </script>)
script_end = html.index('</script>') + len('</script>')
new_html = html[:script_start] + NEW_JS + '\n'

output_path = 'C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch/launch.html'
with open(output_path, 'w', encoding='utf-8') as f:
    f.write(new_html)

print(f'OK: {len(new_html)} bytes written')
print(f'PLATFORM_WALLET count: {new_html.count("const PLATFORM_WALLET")}')
print(f'PANCAKE_ROUTER count: {new_html.count("const PANCAKE_ROUTER")}')
print(f'TOKEN_ABI count: {new_html.count("const TOKEN_ABI")}')
print(f'TOKEN_BYTECODE present: {"TOKEN_BYTECODE" in new_html}')
