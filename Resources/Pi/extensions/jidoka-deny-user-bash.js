export default function jidokaDenyUserBash(pi) {
  pi.on("user_bash", () => ({
    result: {
      output: "JIDOKA_USER_BASH_DENIED",
      exitCode: 126,
      cancelled: false,
      truncated: false,
    },
  }));
}
