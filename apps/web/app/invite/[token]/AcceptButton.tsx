"use client";

const DOWNLOAD_URL = "https://narro.org/grocer";

export function AcceptButton({ token }: { token: string }) {
  function handleClick(e: React.MouseEvent<HTMLAnchorElement>) {
    e.preventDefault();

    // Cancel the App Store fallback if the page goes to background,
    // which means the app opened successfully.
    const timer = setTimeout(() => {
      window.location.href = DOWNLOAD_URL;
    }, 1500);

    document.addEventListener(
      "visibilitychange",
      () => {
        if (document.hidden) clearTimeout(timer);
      },
      { once: true },
    );

    window.location.href = `grocer://invite/${token}`;
  }

  return (
    <a
      href={DOWNLOAD_URL}
      onClick={handleClick}
      className="mt-6 flex min-h-[52px] items-center justify-center rounded-[14px] bg-[#18181b] text-base font-bold text-white no-underline transition-opacity hover:opacity-90 dark:bg-[#f4f4f5] dark:text-[#0b0b0c]"
    >
      Accept Invite
    </a>
  );
}
