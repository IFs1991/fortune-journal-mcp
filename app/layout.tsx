import type { Metadata } from 'next';
import './style.css';
export const metadata: Metadata = {
  title: 'Fortune Journal · Connect',
  description: 'Connect your usual AI to the Fortune Journal calculation engine.',
  robots: {index:false, follow:false},
};
export default function Layout({children}:Readonly<{children:React.ReactNode}>) {
  return <html lang="en"><body>{children}</body></html>;
}
