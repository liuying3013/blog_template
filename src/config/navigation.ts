// src/config/navigation.ts

export interface NavItem {
  label: string;
  href: string;
}

export const mainNav: NavItem[] = [
  { label: "Home", href: "/" },
  { label: "Blog", href: "/blog/" },
];

export const footerNav: NavItem[] = [
  { label: "Blog", href: "/blog/" },
  { label: "RSS", href: "/rss.xml" },
];
