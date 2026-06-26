import type { Metadata } from "next";
import { PostHogProvider } from "./PostHogProvider";
import "./globals.css";

export const metadata: Metadata = {
  title: "Grocer",
  description: "Grocer marketing site",
  metadataBase: new URL("https://grocer.sh"),
  icons: {
    icon: "/app-icon.png",
    apple: "/app-icon.png",
  },
};

export default function RootLayout({
  children
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>
        <PostHogProvider>{children}</PostHogProvider>
      </body>
    </html>
  );
}
