import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Geist } from "next/font/google";

const geist = Geist({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
});

// Where the "Download or Update Grocer" button points. Matches the worker's
// IOS_UPDATE_URL so both surfaces send people to the same place.
const DOWNLOAD_URL = "https://narro.org/grocer";
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

function headline(inviter: string, group: string): string {
  if (inviter && group) return `${inviter} shared “${group}” with you`;
  if (inviter) return `${inviter} wants to share groceries with you`;
  if (group) return `You're invited to “${group}”`;
  return "You've been invited to Grocer";
}

const pageClass =
  "box-border flex min-h-dvh items-center justify-center bg-[#f6f6f7] px-4 pt-6 text-[#18181b] antialiased [padding-bottom:calc(env(safe-area-inset-bottom)+24px)] dark:bg-[#0b0b0c] dark:text-[#f4f4f5]";
const cardClass =
  "w-full max-w-[460px] rounded-3xl border border-black/10 bg-white px-6 pt-5 shadow-[0_12px_40px_rgba(0,0,0,0.08)] [padding-bottom:calc(env(safe-area-inset-bottom)+24px)] dark:border-white/10 dark:bg-[#161618]";
const pillClass =
  "absolute z-10 inline-flex items-center gap-1.5 whitespace-nowrap rounded-full bg-white px-3 py-[7px] text-[13px] font-semibold text-[#18181b] shadow-[0_8px_20px_rgba(0,0,0,0.2)]";
const badgeClass =
  "absolute z-10 inline-flex items-center gap-1.5 whitespace-nowrap rounded-[10px] bg-white px-[11px] py-1.5 text-xs font-bold text-[#18181b] shadow-[0_8px_20px_rgba(0,0,0,0.2)]";

export const metadata: Metadata = {
  title: "You're invited to Grocer",
  description:
    "Shop together in real time, check items off, and get notified when your list changes.",
};

export default async function InvitePage({ params, searchParams }: InvitePageProps) {
  const { token } = await params;
  if (!TOKEN_RE.test(token)) notFound();

  const sp = await searchParams;
  const inviter = clean(sp.inviter);
  const group = clean(sp.group);

  return (
    <main className={`${geist.className} ${pageClass}`}>
      <div className={cardClass}>
        <header className="mb-4 flex items-center justify-between">
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
            className="rounded-full border border-black/10 px-[13px] py-[7px] text-[13px] font-semibold text-current no-underline transition-opacity hover:opacity-70 dark:border-white/10"
            href={MARKETING_URL}
          >
            What is Grocer?
          </a>
        </header>

        <div className="relative flex h-[232px] items-center justify-center overflow-hidden rounded-[20px] bg-[radial-gradient(120%_120%_at_50%_12%,#34d399_0%,#10b981_46%,#059669_100%)]">
          <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(60%_50%_at_50%_42%,rgba(255,255,255,0.45),transparent_70%)]" />
          <span className={`${badgeClass} right-[30px] top-[58px] bg-[#18181b] text-black`}>
            ✓ Added
          </span>
          <span className={`${pillClass} left-[26px] top-10 -rotate-[7deg]`}>🥛 Milk</span>
          <div className="relative z-1 grid  place-items-center rounded-[26%] shadow-xl">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img className="block rounded-[24%]" src="/app-icon.png" alt="" width={88} height={88} />
          </div>
          <span className={`${pillClass} bottom-[46px] right-6 rotate-[6deg]`}>🥕 Carrots</span>
          <span className={`${badgeClass} bottom-10 left-7`}>🛒 Shared</span>
        </div>

        <h1 className="mt-6 text-2xl font-extrabold leading-tight">{headline(inviter, group)}</h1>
        <p className="mt-3 text-[15px] leading-6 text-[#6b7280] dark:text-[#a1a1aa]">
          Add items together, check things off in real time, and get notified
          when your list changes. It&apos;s free and private — no account signup
          required.
        </p>

        <div className="mt-6">
          <p className="mb-3 text-[15px] font-bold">To accept this invite:</p>
          <div className="flex items-center gap-3 py-2 text-[15px] font-medium">
            <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-white text-[13px] font-bold text-black">
              1
            </span>
            <span>Download or update Grocer</span>
          </div>
          <div className="flex items-center gap-3 py-2 text-[15px] font-medium">
            <span className="grid h-6 w-6 shrink-0 place-items-center rounded-full bg-white text-[13px] font-bold text-black">
              2
            </span>
            <span>Open this invite again</span>
          </div>
        </div>

        <a
          className="mt-[22px] flex min-h-[52px] items-center justify-center rounded-[14px] bg-[#18181b] text-base font-bold text-white no-underline transition-opacity hover:opacity-90 dark:bg-[#f4f4f5] dark:text-[#0b0b0c]"
          href={DOWNLOAD_URL}
        >
          Download or Update Grocer
        </a>

        <footer className="mt-5 text-center text-[11px] text-[#6b7280] opacity-75 dark:text-[#a1a1aa]">
          © {new Date().getFullYear()} Narro. All rights reserved.
        </footer>
      </div>
    </main>
  );
}
