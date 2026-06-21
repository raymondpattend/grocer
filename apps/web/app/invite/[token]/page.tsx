import type { Metadata, Viewport } from "next";
import { notFound } from "next/navigation";
import { Geist } from "next/font/google";
import { AcceptButton } from "./AcceptButton";

const geist = Geist({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
});

const MARKETING_URL = "https://grocer.sh";

const TOKEN_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{5,127}$/;

type SearchParams = Record<string, string | string[] | undefined>;

type InvitePageProps = {
  params: Promise<{ token: string }>;
  searchParams: Promise<SearchParams>;
};

function clean(value: string | string[] | undefined): string {
  const raw = Array.isArray(value) ? value[0] : value;
  return (raw ?? "").trim().slice(0, 80);
}

// Client-side invite TTL. The app stamps links with an `exp` query item (Unix
// seconds); we mirror its check here so an expired link shows an "expired" state
// instead of the join CTA. Not a security boundary — the param is plaintext and
// strippable — it just turns away people who open a stale link. Links without
// `exp` (older builds) are treated as valid. Kept in sync with
// `ShareInviteLink.isExpired` in the iOS app.
function isExpired(value: string | string[] | undefined, now: number = Date.now()): boolean {
  const raw = Array.isArray(value) ? value[0] : value;
  if (!raw) return false;
  const seconds = Number(raw);
  if (!Number.isFinite(seconds) || seconds <= 0) return false;
  return seconds * 1000 < now;
}

function headline(inviter: string, group: string): string {
  if (inviter && group) return `${inviter} invited you to join "${group}" on Grocer`;
  if (inviter) return `${inviter} invited you to Grocer`;
  if (group) return `You're invited to "${group}" on Grocer`;
  return "You've been invited to Grocer";
}

// Themes the Safari navigation bar / status bar to match the page background.
export const viewport: Viewport = {
  viewportFit: "cover",
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#f6f6f7" },
    { media: "(prefers-color-scheme: dark)", color: "#0b0b0c" },
  ],
};

export async function generateMetadata({ searchParams }: InvitePageProps): Promise<Metadata> {
  const sp = await searchParams;
  const inviter = clean(sp.inviter);
  const group = clean(sp.group);
  const title = isExpired(sp.exp) ? "This Grocer invite has expired" : headline(inviter, group);
  const description =
    "Add items together, check things off in real time, and keep everyone synced.";
  return {
    title,
    description,
    metadataBase: new URL("https://share.grocer.sh"),
    openGraph: {
      title,
      description,
      images: [{ url: "/og-image.png", width: 1024, height: 1024 }],
      siteName: "Grocer",
      type: "website",
    },
    twitter: {
      card: "summary",
      title,
      description,
      images: ["/og-image.png"],
    },
  };
}

const pillClass =
  "absolute z-10 inline-flex items-center gap-1.5 whitespace-nowrap rounded-full bg-white px-3 py-[7px] text-[13px] font-semibold text-[#18181b] shadow-[0_8px_20px_rgba(0,0,0,0.2)]";
const badgeClass =
  "absolute z-10 inline-flex items-center gap-1.5 whitespace-nowrap rounded-[10px] bg-white px-[11px] py-1.5 text-xs font-bold text-[#18181b] shadow-[0_8px_20px_rgba(0,0,0,0.2)]";

export default async function InvitePage({ params, searchParams }: InvitePageProps) {
  const { token } = await params;
  if (!TOKEN_RE.test(token)) notFound();

  const sp = await searchParams;
  const inviter = clean(sp.inviter);
  const group = clean(sp.group);
  const expired = isExpired(sp.exp);

  return (
    <main
      className={`${geist.className} box-border flex min-h-dvh items-stretch justify-center bg-[#f6f6f7] px-0 pt-0 text-[#18181b] antialiased sm:items-center sm:px-4 sm:pt-6 sm:[padding-bottom:calc(env(safe-area-inset-bottom)+24px)] dark:bg-[#0b0b0c] dark:text-[#f4f4f5]`}
    >
      <div className="flex w-full flex-col overflow-hidden border-y border-black/10 bg-white [padding-bottom:calc(env(safe-area-inset-bottom)+20px)] sm:min-h-[740px] sm:max-w-[560px] sm:rounded-3xl sm:border sm:shadow-[0_12px_40px_rgba(0,0,0,0.08)] sm:[padding-bottom:0] dark:border-white/10 dark:bg-[#161618]">
        {/* Header */}
        <header className="flex items-center justify-between px-6 pt-5">
          <div className="flex items-center gap-[9px]">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              className="block rounded-[22%]"
              src="/app-icon.png"
              alt="Grocer"
              width={32}
              height={32}
            />
            <span className="text-[19px] font-extrabold">Grocer</span>
          </div>
          <a
            className="text-[13px] font-medium text-[#6b7280] no-underline transition-opacity hover:opacity-70 dark:text-[#a1a1aa]"
            href={MARKETING_URL}
          >
            What is Grocer?
          </a>
        </header>

        {/* Hero — between header and title */}
        <div className="relative mx-6 mt-4 flex h-auto flex-1 items-center justify-center overflow-hidden rounded-[20px] bg-[radial-gradient(120%_120%_at_50%_12%,#34d399_0%,#10b981_46%,#059669_100%)]">
          <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(60%_50%_at_50%_42%,rgba(255,255,255,0.45),transparent_70%)]" />
          <span className={`${badgeClass} right-[26px] top-10 bg-[#18181b] !text-black`}>
            ✓ Added
          </span>
          <span className={`${pillClass} left-5 top-7 -rotate-[7deg]`}>🥛 Milk</span>
          <div className="relative z-1 grid place-items-center rounded-[26%] shadow-xl">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              className="block rounded-[24%]"
              src="/app-icon.png"
              alt=""
              width={72}
              height={72}
            />
          </div>
          <span className={`${pillClass} bottom-7 right-4 rotate-[6deg]`}>🥕 Carrots</span>
          <span className={`${badgeClass} bottom-7 left-5`}>🛒 Shared</span>
        </div>

        {/* Invite copy + CTA */}
        <div className="px-6 pt-5 pb-2">
          {expired ? (
            <>
              <h1 className="text-[26px] font-extrabold leading-tight">
                This invite link has expired
              </h1>
              <p className="mt-4 text-[14px] leading-relaxed text-[#6b7280] dark:text-[#a1a1aa]">
                Ask {inviter || "the group owner"} to send you a new invite link
                {group ? ` for "${group}"` : ""}.
              </p>
              <a
                href={MARKETING_URL}
                className="mt-6 flex min-h-[52px] items-center justify-center rounded-[14px] bg-[#18181b] text-base font-bold text-white no-underline transition-opacity hover:opacity-90 dark:bg-[#f4f4f5] dark:text-[#0b0b0c]"
              >
                Learn about Grocer
              </a>
            </>
          ) : (
            <>
              <h1 className="text-[26px] font-extrabold leading-tight">
                {headline(inviter, group)}
              </h1>

              <div className="mt-4 space-y-2">
                <p className="text-[12px] font-semibold uppercase tracking-wide text-[#6b7280] dark:text-[#a1a1aa]">
                  To accept this invite
                </p>
                <div className="flex items-start gap-3 text-[13px] text-[#6b7280] dark:text-[#a1a1aa]">
                  <span className="mt-px grid h-5 w-5 shrink-0 place-items-center rounded-full bg-[#f0f0f0] text-[11px] font-bold text-[#18181b] dark:bg-[#2a2a2a] dark:text-[#f4f4f5]">
                    1
                  </span>
                  <span>Download or update Grocer from the App Store</span>
                </div>
                <div className="flex items-start gap-3 text-[13px] text-[#6b7280] dark:text-[#a1a1aa]">
                  <span className="mt-px grid h-5 w-5 shrink-0 place-items-center rounded-full bg-[#f0f0f0] text-[11px] font-bold text-[#18181b] dark:bg-[#2a2a2a] dark:text-[#f4f4f5]">
                    2
                  </span>
                  <span>Open this invite link again to join the group</span>
                </div>
              </div>

              <AcceptButton token={token} />
            </>
          )}
        </div>

        <footer className="px-6 pb-5 text-center text-[11px] text-[#6b7280] opacity-60 dark:text-[#a1a1aa]">
          © {new Date().getFullYear()} Narro. All rights reserved.
        </footer>
      </div>
    </main>
  );
}
