import { type ClassValue, clsx } from "clsx";
import { twMerge } from "tailwind-merge";

// Standard shadcn-svelte class merge helper.
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
