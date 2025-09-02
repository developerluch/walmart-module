const puppeteer = require('puppeteer');

class WalmartAPIDiscovery {
    constructor() {
        this.browser = null;
        this.page = null;
        this.requests = [];
        this.apiEndpoints = new Set();
    }

    async initialize() {
        this.browser = await puppeteer.launch({
            headless: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
        });

        this.page = await this.browser.newPage();

        // Intercept all network requests
        await this.page.setRequestInterception(true);

        this.page.on('request', (request) => {
            const url = request.url();
            const method = request.method();
            const headers = request.headers();

            // Log all requests
            this.requests.push({
                url,
                method,
                headers,
                timestamp: new Date().toISOString()
            });

            // Filter for API endpoints
            if (this.isAPIEndpoint(url)) {
                this.apiEndpoints.add(JSON.stringify({
                    url,
                    method,
                    headers: this.sanitizeHeaders(headers)
                }, null, 2));
            }

            request.continue();
        });

        this.page.on('response', (response) => {
            const url = response.url();
            const status = response.status();
            const contentType = response.headers()['content-type'] || '';

            // Log responses for API endpoints
            if (this.isAPIEndpoint(url)) {
                console.log(`[${new Date().toISOString()}] ${response.request().method()} ${url} -> ${status} (${contentType})`);
            }
        });
    }

    isAPIEndpoint(url) {
        return (
            url.includes('walmart.com') &&
            (
                url.includes('/api/') ||
                url.includes('/orchestra/') ||
                url.includes('graphql') ||
                url.includes('cart') ||
                url.includes('checkout') ||
                url.includes('account') ||
                url.match(/\.(json|xml)$/) ||
                url.includes('?') // Likely API calls with query params
            ) &&
            !url.includes('.js') &&
            !url.includes('.css') &&
            !url.includes('.png') &&
            !url.includes('.jpg') &&
            !url.includes('.svg')
        );
    }

    sanitizeHeaders(headers) {
        const sanitized = { ...headers };
        // Remove sensitive headers
        delete sanitized.authorization;
        delete sanitized.cookie;
        delete sanitized['x-csrf-token'];
        return sanitized;
    }

    async navigateToProduct(productId) {
        console.log(`\n=== Navigating to Product: ${productId} ===`);
        try {
            await this.page.goto(`https://www.walmart.com/ip/${productId}`, {
                waitUntil: 'networkidle2',
                timeout: 30000
            });
            await this.page.waitForTimeout(2000); // Wait for dynamic content
        } catch (error) {
            console.error('Error navigating to product:', error.message);
        }
    }

    async addToCart() {
        console.log('\n=== Attempting to Add to Cart ===');

        try {
            // Look for "Add to Cart" button
            const addToCartSelectors = [
                '[data-testid="add-to-cart-btn"]',
                'button[data-automation-id="add-to-cart-btn"]',
                'button:contains("Add to cart")',
                '.add-to-cart-btn',
                '[aria-label*="Add to cart"]'
            ];

            for (const selector of addToCartSelectors) {
                try {
                    await this.page.waitForSelector(selector, { timeout: 2000 });
                    await this.page.click(selector);
                    console.log(`Clicked Add to Cart button: ${selector}`);
                    await this.page.waitForTimeout(3000);
                    break;
                } catch (e) {
                    // Continue to next selector
                }
            }
        } catch (error) {
            console.error('Error adding to cart:', error.message);
        }
    }

    async navigateToCart() {
        console.log('\n=== Navigating to Cart ===');

        try {
            // Try multiple ways to navigate to cart
            const cartSelectors = [
                '[data-testid="cart-link"]',
                'a[href*="/cart"]',
                '[aria-label*="cart"]',
                '.cart-link'
            ];

            for (const selector of cartSelectors) {
                try {
                    const element = await this.page.$(selector);
                    if (element) {
                        await element.click();
                        console.log(`Clicked cart link: ${selector}`);
                        await this.page.waitForTimeout(3000);
                        break;
                    }
                } catch (e) {
                    // Continue to next selector
                }
            }

            // Fallback: navigate directly
            await this.page.goto('https://www.walmart.com/cart', {
                waitUntil: 'networkidle2',
                timeout: 10000
            });
        } catch (error) {
            console.error('Error navigating to cart:', error.message);
        }
    }

    async startCheckout() {
        console.log('\n=== Starting Checkout Process ===');

        try {
            // Look for checkout button
            const checkoutSelectors = [
                '[data-testid="checkout-btn"]',
                'button[data-automation-id="checkout-btn"]',
                'button:contains("Check out")',
                '[aria-label*="checkout"]'
            ];

            for (const selector of checkoutSelectors) {
                try {
                    await this.page.waitForSelector(selector, { timeout: 2000 });
                    await this.page.click(selector);
                    console.log(`Clicked checkout button: ${selector}`);
                    await this.page.waitForTimeout(3000);
                    break;
                } catch (e) {
                    // Continue to next selector
                }
            }
        } catch (error) {
            console.error('Error starting checkout:', error.message);
        }
    }

    async fillShippingInfo() {
        console.log('\n=== Filling Shipping Information ===');

        try {
            // Wait for shipping form
            await this.page.waitForSelector('form[action*="shipping"]', { timeout: 10000 });

            // Fill shipping form fields
            const shippingFields = {
                'input[name*="firstName"]': 'John',
                'input[name*="lastName"]': 'Doe',
                'input[name*="address"]': '123 Main St',
                'input[name*="city"]': 'Anytown',
                'input[name*="zipCode"]': '12345',
                'input[name*="phone"]': '555-0123'
            };

            for (const [selector, value] of Object.entries(shippingFields)) {
                try {
                    await this.page.type(selector, value, { delay: 100 });
                    console.log(`Filled ${selector}: ${value}`);
                } catch (e) {
                    console.log(`Could not fill ${selector}`);
                }
            }

            await this.page.waitForTimeout(2000);
        } catch (error) {
            console.error('Error filling shipping info:', error.message);
        }
    }

    async fillPaymentInfo() {
        console.log('\n=== Filling Payment Information ===');

        try {
            // Wait for payment form
            await this.page.waitForSelector('form[action*="payment"]', { timeout: 10000 });

            // Fill payment form fields
            const paymentFields = {
                'input[name*="cardNumber"]': '4111111111111111',
                'input[name*="expiryMonth"]': '12',
                'input[name*="expiryYear"]': '2025',
                'input[name*="cvv"]': '123'
            };

            for (const [selector, value] of Object.entries(paymentFields)) {
                try {
                    await this.page.type(selector, value, { delay: 100 });
                    console.log(`Filled ${selector}: ${value}`);
                } catch (e) {
                    console.log(`Could not fill ${selector}`);
                }
            }

            await this.page.waitForTimeout(2000);
        } catch (error) {
            console.error('Error filling payment info:', error.message);
        }
    }

    async completeOrder() {
        console.log('\n=== Completing Order ===');

        try {
            // Look for place order button
            const placeOrderSelectors = [
                '[data-testid="place-order-btn"]',
                'button[data-automation-id="place-order-btn"]',
                'button:contains("Place order")',
                '[aria-label*="place order"]'
            ];

            for (const selector of placeOrderSelectors) {
                try {
                    await this.page.waitForSelector(selector, { timeout: 2000 });
                    await this.page.click(selector);
                    console.log(`Clicked place order button: ${selector}`);
                    await this.page.waitForTimeout(5000);
                    break;
                } catch (e) {
                    // Continue to next selector
                }
            }
        } catch (error) {
            console.error('Error completing order:', error.message);
        }
    }

    async runCompleteFlow(productId) {
        console.log('🚀 Starting Walmart API Discovery Flow');
        console.log('=' .repeat(50));

        try {
            await this.initialize();

            // Execute the complete workflow
            await this.navigateToProduct(productId);
            await this.addToCart();
            await this.navigateToCart();
            await this.startCheckout();
            await this.fillShippingInfo();
            await this.fillPaymentInfo();
            await this.completeOrder();

            // Wait for any final API calls
            await this.page.waitForTimeout(5000);

        } catch (error) {
            console.error('Error during flow execution:', error);
        } finally {
            await this.generateReport();
            await this.close();
        }
    }

    async generateReport() {
        console.log('\n📊 API Discovery Report');
        console.log('=' .repeat(50));

        console.log(`\nTotal requests captured: ${this.requests.length}`);
        console.log(`Unique API endpoints discovered: ${this.apiEndpoints.size}`);

        console.log('\n🔗 Discovered API Endpoints:');
        console.log('-'.repeat(30));

        const endpoints = Array.from(this.apiEndpoints).map(endpoint => JSON.parse(endpoint));

        // Group by category
        const categories = {
            cart: [],
            checkout: [],
            account: [],
            graphql: [],
            other: []
        };

        endpoints.forEach(endpoint => {
            const url = endpoint.url.toLowerCase();
            if (url.includes('cart')) {
                categories.cart.push(endpoint);
            } else if (url.includes('checkout')) {
                categories.checkout.push(endpoint);
            } else if (url.includes('account')) {
                categories.account.push(endpoint);
            } else if (url.includes('graphql')) {
                categories.graphql.push(endpoint);
            } else {
                categories.other.push(endpoint);
            }
        });

        Object.entries(categories).forEach(([category, endpoints]) => {
            if (endpoints.length > 0) {
                console.log(`\n${category.toUpperCase()} APIs (${endpoints.length}):`);
                endpoints.forEach(endpoint => {
                    console.log(`  ${endpoint.method} ${endpoint.url}`);
                });
            }
        });

        // Save detailed report
        const report = {
            timestamp: new Date().toISOString(),
            totalRequests: this.requests.length,
            apiEndpoints: endpoints,
            allRequests: this.requests
        };

        const fs = require('fs');
        fs.writeFileSync('walmart-api-discovery-report.json', JSON.stringify(report, null, 2));
        console.log('\n📄 Detailed report saved to: walmart-api-discovery-report.json');
    }

    async close() {
        if (this.browser) {
            await this.browser.close();
        }
    }
}

// Run the discovery if called directly
if (require.main === module) {
    const productId = process.argv[2] || '14225185'; // Default: some Walmart product

    console.log(`Starting Walmart API discovery for product: ${productId}`);
    console.log('Make sure you have Node.js and puppeteer installed:');
    console.log('npm install puppeteer');
    console.log('');

    const discovery = new WalmartAPIDiscovery();
    discovery.runCompleteFlow(productId).catch(console.error);
}

module.exports = WalmartAPIDiscovery;
