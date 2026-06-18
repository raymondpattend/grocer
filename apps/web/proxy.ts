import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// The invite page lives on its own subdomain: share.grocer.sh/<token>. The
// public-facing URL stays clean; internally we rewrite onto the /invite/<token>
// route. Anything hitting share.grocer.sh without a valid token (the bare
// domain, junk paths, crawlers asking for /robots.txt, etc.) is bounced to the
// marketing site.
const SHARE_HOST = "share.grocer.sh";
const FALLBACK = "https://grocer.sh";

// A share token is a single path segment of url-safe characters. The app mints
// it as a base64url-encoded CloudKit share URL (which can run long), so the
// upper bound is generous; it still rejects empty/multi-segment/obviously-wrong
// paths.
const TOKEN_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{5,511}$/;

// Apple App Site Association — enables the app's `applinks:share.grocer.sh`
// entitlement so tapping a share link opens Grocer. Served straight from the
// proxy (Next won't serve dotfiles from public/, and Apple fetches this over
// share.grocer.sh where every other path redirects). Keep the appID in sync
// with the app's `<teamID>.<bundleID>`.
const AASA = JSON.stringify({
  applinks: {
    details: [
      {
        appIDs: ["LNY6LA39SW.org.narro.grocer"],
        components: [
          { "/": "/.well-known/*", exclude: true },
          { "/": "/*" },
        ],
      },
    ],
  },
});
const AASA_PATH = "/.well-known/apple-app-site-association";

export function proxy(req: NextRequest) {
  const host = (req.headers.get("host") ?? "").toLowerCase().split(":")[0];
  const { pathname } = req.nextUrl;

  if (pathname === AASA_PATH) {
    return new NextResponse(AASA, {
      headers: { "content-type": "application/json" },
    });
  }

  if (host !== SHARE_HOST) {
    // The /invite route is an implementation detail of the share subdomain —
    // don't expose it on grocer.sh. (Allowed locally so the page is testable.)
    if (pathname.startsWith("/invite") && process.env.NODE_ENV === "production") {
      return NextResponse.redirect(FALLBACK);
    }
    return NextResponse.next();
  }

  const segments = pathname.split("/").filter(Boolean);
  const token = segments[0] ?? "";

  if (segments.length !== 1 || !TOKEN_RE.test(token)) {
    return NextResponse.redirect(FALLBACK);
  }

  const url = req.nextUrl.clone();
  url.pathname = `/invite/${token}`;
  return NextResponse.rewrite(url);
}

export const config = {
  // Run on everything except Next internals and the icon so the share host is
  // fully covered. The association file is matched here (and short-circuited
  // above) rather than excluded, so Apple's fetch never falls through.
  matcher: ["/((?!_next/|favicon.ico|app-icon.png).*)"],
};
