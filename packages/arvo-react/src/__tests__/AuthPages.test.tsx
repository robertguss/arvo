import "@testing-library/jest-dom/vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { LoginPage } from "../pages/Auth/Login";
import { MfaChallengePage } from "../pages/Auth/MfaChallenge";
import { RegisterPage } from "../pages/Auth/Register";
import { SecuritySettingsPage } from "../pages/Settings/Security";

vi.mock("@inertiajs/react", () => ({
  router: {
    post: vi.fn(),
    delete: vi.fn(),
    reload: vi.fn(),
  },
  useForm: <T extends Record<string, unknown>>(initial: T) => ({
    data: initial,
    processing: false,
    setData: vi.fn(),
    post: vi.fn(),
    reset: vi.fn(),
  }),
}));

describe("Arvo Auth & Security pages", () => {
  it("renders accessible Login validation errors and OIDC links", () => {
    render(
      <LoginPage
        errors={{ email: "invalid email or password" }}
        oidcProviders={[{ id: "github", label: "GitHub", href: "/auth/oidc/github/start" }]}
      />,
    );
    expect(screen.getByLabelText("Email")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByRole("alert")).toHaveTextContent("invalid email or password");
    expect(screen.getByText("Continue with GitHub")).toBeInTheDocument();
  });

  it("toggles between TOTP and recovery code forms on MFA challenge", async () => {
    const user = userEvent.setup();
    render(<MfaChallengePage />);
    expect(screen.getByLabelText("6-digit code")).toBeInTheDocument();
    await user.click(screen.getByText("Use a recovery code instead"));
    expect(screen.getByLabelText("Recovery code")).toBeInTheDocument();
  });

  it("renders Register and Security settings sections", () => {
    render(<RegisterPage errors={{ password: "too short" }} />);
    expect(screen.getByRole("alert")).toHaveTextContent("too short");

    render(
      <SecuritySettingsPage
        userEmail="ada@example.com"
        mfaEnabled={false}
        needsSudo
        sessions={[]}
        passkeys={[]}
        apiTokens={[]}
      />,
    );
    expect(screen.getByText("Confirm password (Sudo mode)")).toBeInTheDocument();
  });
});
