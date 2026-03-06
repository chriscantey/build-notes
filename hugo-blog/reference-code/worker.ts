/**
 * Newsletter Subscribe Worker
 * Handles subscription requests and forwards to Buttondown API
 * Deploy: wrangler deploy (from worker/ directory)
 * Secret: wrangler secret put BUTTONDOWN_API_KEY
 */

interface Env {
  BUTTONDOWN_API_KEY: string;
}

interface ButtondownResponse {
  id?: string;
  email?: string;
  creation_date?: string;
  detail?: string;
  email_address?: string[];
}

const ALLOWED_ORIGINS = [
  'https://yoursite.com',
  'https://www.yoursite.com',
  'http://localhost:1313', // Hugo dev server
];

function corsHeaders(origin: string | null): HeadersInit {
  const allowedOrigin = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Type': 'application/json',
  };
}

function isValidEmail(email: string): boolean {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return emailRegex.test(email) && email.length <= 254;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const origin = request.headers.get('Origin');
    const headers = corsHeaders(origin);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers });
    }

    if (request.method !== 'POST') {
      return new Response(
        JSON.stringify({ success: false, error: 'Method not allowed' }),
        { status: 405, headers }
      );
    }

    try {
      const body = await request.json() as { email?: string };
      const email = body.email?.trim().toLowerCase();

      if (!email) {
        return new Response(
          JSON.stringify({ success: false, error: 'Email is required' }),
          { status: 400, headers }
        );
      }

      if (!isValidEmail(email)) {
        return new Response(
          JSON.stringify({ success: false, error: 'Invalid email format' }),
          { status: 400, headers }
        );
      }

      const clientIP = request.headers.get('CF-Connecting-IP') ||
                       request.headers.get('X-Forwarded-For')?.split(',')[0]?.trim() ||
                       '';

      const buttondownResponse = await fetch('https://api.buttondown.com/v1/subscribers', {
        method: 'POST',
        headers: {
          'Authorization': `Token ${env.BUTTONDOWN_API_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          email_address: email,
          referrer_url: request.headers.get('Referer') || origin || 'https://yoursite.com',
          ip_address: clientIP,
        }),
      });

      const data = await buttondownResponse.json() as ButtondownResponse;

      if (buttondownResponse.ok) {
        return new Response(
          JSON.stringify({ success: true, message: 'Check your email to confirm your subscription.' }),
          { status: 200, headers }
        );
      }

      if (buttondownResponse.status === 400) {
        if (data.email_address?.some(msg => msg.includes('already'))) {
          return new Response(
            JSON.stringify({ success: true, message: "You're already subscribed." }),
            { status: 200, headers }
          );
        }
      }

      if (buttondownResponse.status === 429) {
        return new Response(
          JSON.stringify({ success: false, error: 'Too many requests. Please try again later.' }),
          { status: 429, headers }
        );
      }

      console.error('Buttondown error:', buttondownResponse.status, data);
      return new Response(
        JSON.stringify({ success: false, error: 'Unable to subscribe. Please try again.' }),
        { status: 500, headers }
      );

    } catch (err) {
      console.error('Worker error:', err);
      return new Response(
        JSON.stringify({ success: false, error: 'Something went wrong. Please try again.' }),
        { status: 500, headers }
      );
    }
  },
};
