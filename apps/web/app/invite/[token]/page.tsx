import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Geist } from "next/font/google";
import styles from "./invite.module.css";

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
    <main className={`${geist.className} ${styles.page}`}>
      <div className={styles.card}>
        <header className={styles.topbar}>
          <div className={styles.brand}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              className={styles.brandLogo}
              src="/app-icon.png"
              alt="Grocer"
              width={32}
              height={32}
            />
            <span className={styles.brandName}>Grocer</span>
          </div>
          <a className={styles.whatLink} href={MARKETING_URL}>
            What is Grocer?
          </a>
        </header>

        <div className={styles.hero}>
          <div className={styles.heroGlow} />
          <span className={`${styles.badge} ${styles.badgeCheck}`}>✓ Added</span>
          <span className={`${styles.pill} ${styles.pillA}`}>🥛 Milk</span>
          <div className={styles.heroIcon}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/app-icon.png" alt="" width={88} height={88} />
          </div>
          <span className={`${styles.pill} ${styles.pillB}`}>🥕 Carrots</span>
          <span className={`${styles.badge} ${styles.badgeShared}`}>🛒 Shared</span>
        </div>

        <h1 className={styles.title}>{headline(inviter, group)}</h1>
        <p className={styles.subtitle}>
          Add items together, check things off in real time, and get notified
          when your list changes. It&apos;s free and private — no account signup
          required.
        </p>

        <div className={styles.steps}>
          <p className={styles.stepsLabel}>To accept this invite:</p>
          <div className={styles.step}>
            <span className={styles.stepNum}>1</span>
            <span>Download or update Grocer</span>
          </div>
          <div className={styles.step}>
            <span className={styles.stepNum}>2</span>
            <span>Open this invite again</span>
          </div>
        </div>

        <a className={styles.cta} href={DOWNLOAD_URL}>
          Download or Update Grocer
        </a>

        <footer className={styles.footer}>
          © {new Date().getFullYear()} Narro. All rights reserved.
        </footer>
      </div>
    </main>
  );
}
