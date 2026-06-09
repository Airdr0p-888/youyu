/**
 * 分红自动触发 Bot
 * 
 * 用法：
 *   node dividend_bot.js
 * 
 * 环境变量（推荐）：
 *   BSC_RPC      - BSC RPC URL（默认 https://bsc-dataseed1.binance.org）
 *   PRIVATE_KEY  - 触发分红的钱包私钥（可以不填，任何人可调 distribute）
 *   TOKEN_ADDR   - SimpleToken 地址
 *   DIST_ADDR    - DividendDistributor 地址
 *   INTERVAL     - 检查间隔（秒，默认 60）
 * 
 * 也可以直接改下方 CONFIG
 */

const { ethers } = require("ethers");

// ── 配置 ──
const CONFIG = {
  rpc:      process.env.BSC_RPC      || "https://data-seed-prebsc-1-s1.binance.org:8545",  // BSC Testnet
  privKey:  process.env.PRIVATE_KEY  || "",
  token:    process.env.TOKEN_ADDR   || "",
  dist:     process.env.DIST_ADDR    || "",
  interval: parseInt(process.env.INTERVAL) || 60,  // 秒
};

// DividendDistributor ABI（最小化）
const DIST_ABI = [
  "function distribute() external",
  "function holdersCount() external view returns (uint256)",
  "function minDividendBalance() external view returns (uint256)",
];

// SimpleToken ABI（只需要 balanceOf）
const TOKEN_ABI = [
  "function balanceOf(address) external view returns (uint256)",
  "event SellOccurred(address indexed seller, uint256 amount)",
];

let provider, wallet, tokenContract, distContract;
let sellEventTimer = null;

function log(msg) {
  console.log(`[${new Date().toLocaleTimeString()}] ${msg}`);
}

async function init() {
  if (!CONFIG.token || !CONFIG.dist) {
    console.error("❌ 请设置 TOKEN_ADDR 和 DIST_ADDR 环境变量，或修改脚本中的 CONFIG");
    process.exit(1);
  }

  provider = new ethers.providers.JsonRpcProvider(CONFIG.rpc);
  
  if (CONFIG.privKey) {
    wallet = new ethers.Wallet(CONFIG.privKey, provider);
    log("✅ 钱包已加载: " + wallet.address);
  } else {
    wallet = ethers.Wallet.createRandom().connect(provider);
    log("⚠️  未设置 PRIVATE_KEY，分红触发可能因 gas 不足失败");
  }

  tokenContract = new ethers.Contract(CONFIG.token, TOKEN_ABI, wallet);
  distContract  = new ethers.Contract(CONFIG.dist,  DIST_ABI,  wallet);

  log(`📋 代币合约: ${CONFIG.token}`);
  log(`📋 分红合约: ${CONFIG.dist}`);
}

async function checkAndDistribute() {
  try {
    // 读取分红池代币余额
    const tokenBal = await tokenContract.balanceOf(CONFIG.dist);
    const holdersCount = await distContract.holdersCount();
    const tokenDec = ethers.utils.formatEther(tokenBal);

    log(`📊 分红池余额: ${parseFloat(tokenDec).toFixed(4)} 个 | 分红人数: ${holdersCount}`);

    if (tokenBal.isZero()) {
      return;
    }

    if (holdersCount === 0) {
      log("⏭️  无分红对象，跳过");
      return;
    }

    // 触发分红
    log("💸 触发分红...");
    const tx = await distContract.distribute({ gasLimit: 800000 });
    log(`⏳ 交易已发送: ${tx.hash}`);
    await tx.wait(1);
    log("✅ 分红完成！");

  } catch (e) {
    // distribute() 内部会在 threshold 不够时静默返回，不会报错
    // 这里只捕获真正的异常
    const msg = e.message || String(e);
    if (msg.includes("NoHolders")) {
      log("⏭️  无分红对象");
    } else if (msg.includes("reentrant")) {
      log("⏭️  分红合约正在执行中，跳过");
    } else if (!msg.includes("execution reverted")) {
      log("❌ 异常: " + msg);
    }
  }
}

async function listenSellEvents() {
  log("👂 监听 SellOccurred 事件...");
  tokenContract.on("SellOccurred", async (seller, amount) => {
    log(`🔔 检测到卖出: ${seller} | ${ethers.utils.formatEther(amount)} 个`);
    // 冷却 5s，防止连续卖出时重复触发
    clearTimeout(sellEventTimer);
    sellEventTimer = setTimeout(async () => {
      await checkAndDistribute();
    }, 5000);
  });
}

async function main() {
  console.log("\n🔧 ===== 分红自动触发 Bot =====");
  await init();

  // 立即检查一次
  await checkAndDistribute();

  // 定时检查
  log(`⏰ 定时检查间隔: ${CONFIG.interval} 秒`);
  setInterval(checkAndDistribute, CONFIG.interval * 1000);

  // 事件监听（更及时的触发）
  await listenSellEvents();
}

main().catch(e => { console.error("FATAL:", e); process.exit(1); });
