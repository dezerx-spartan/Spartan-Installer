const puppeteer = require("puppeteer");
(async () => {
// Launch Chrome bypassing the Docker sandbox limits
    const browser = await puppeteer.launch({ 
        args: [
            "--no-sandbox", 
            "--disable-setuid-sandbox",
            "--host-resolver-rules=MAP spartan.test.blipzoo.ovh 127.0.0.1",
            "--ignore-certificate-errors",
            "--ignore-certificate-errors-spki-list"
        ],
        ignoreHTTPSErrors: true
    });
    const page = await browser.newPage();

    await page.setViewport({ width: 1920, height: 1080 });

    console.log("Navigating to dashboard...");
    try {
        await page.goto("https://spartan.test.blipzoo.ovh/login", { 
            waitUntil: "networkidle2",
            timeout: 30000 
        });

        console.log("Taking picture...");
        await page.screenshot({ path: "/opt/spartan-installer/dashboard.png", fullPage: true });
        console.log("Screenshot saved to /opt/spartan-installer/dashboard.png");

    } catch (error) {
        console.error("Failed to capture screenshot:", error.message);
        process.exit(1);
    } finally {
        await browser.close();
    }
})();