using Ecomm.Data;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;

namespace Ecomm.Controllers;

/// <summary>
/// Posiran-only lightweight login endpoint. It deliberately performs only Identity
/// authentication and redirect; branch/book scope work is resolved after login.
/// </summary>
public sealed class PosiranAuthController : Controller
{
    private readonly SignInManager<ApplicationUser> _signInManager;
    private readonly ILogger<PosiranAuthController> _logger;

    public PosiranAuthController(SignInManager<ApplicationUser> signInManager, ILogger<PosiranAuthController> logger)
    {
        _signInManager = signInManager;
        _logger = logger;
    }

    [HttpPost]
    [IgnoreAntiforgeryToken]
    public async Task<IActionResult> Login()
    {
        var form = await Request.ReadFormAsync();
        var nationalCode = form["NationalCode"].ToString().Trim();
        var password = form["Password"].ToString();
        var rememberMe = string.Equals(form["RememberMe"].ToString(), "on", StringComparison.OrdinalIgnoreCase);

        if (string.IsNullOrWhiteSpace(nationalCode) || string.IsNullOrWhiteSpace(password))
            return Redirect("/Account/Login?error=1");

        try
        {
            var result = await _signInManager.PasswordSignInAsync(nationalCode, password, rememberMe, lockoutOnFailure: false);
            if (!result.Succeeded)
                return Redirect("/Account/Login?error=1");

            _logger.LogInformation("Posiran login completed for {UserName}; scope initialization deferred.", nationalCode);
            return Redirect("/Dashboard");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Posiran login failed for {UserName}", nationalCode);
            return Redirect("/Account/Login?error=server");
        }
    }
}
