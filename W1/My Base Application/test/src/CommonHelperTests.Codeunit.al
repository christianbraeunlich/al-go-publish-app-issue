namespace christianbraeunlich.MyBaseApplication.Tests;

using christianbraeunlich.MyBaseApplication;
using System.TestLibraries.Utilities;

codeunit 71900 CommonHelperTests
{
    Subtype = Test;

    trigger OnRun()
    begin

    end;

    var
        Assert: Codeunit "Library Assert";

    [Test]
    procedure TestConvertSecondsToMinutes()
    var
        commonHelper: Codeunit CommonHelper;
    begin
        Assert.AreEqual(2, commonHelper.ConvertSecondsIntoMinutes(120), 'Expected 2 minutes');
    end;

}