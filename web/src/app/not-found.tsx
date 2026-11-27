import Link from "next/link";

export default function NotFound() {
  return (
    <div className="page narrow">
      <header className="page-head">
        <h1>Ghost looked everywhere.</h1>
        <p>This page isn't here. It may have moved, or the link has a typo.</p>
      </header>
      <Link className="button primary" href="/">
        Back to the homepage
      </Link>
    </div>
  );
}
