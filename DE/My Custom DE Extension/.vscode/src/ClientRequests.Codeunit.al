namespace christianbraeunlich.MyCustomDEExtension;

codeunit 72000 ClientRequests
{
    trigger OnRun()
    begin

    end;

    procedure WeekdayAbbreviation(weekDay: Integer): Text[2]
    begin
        case weekDay of
            1:
                exit('Mo');
            2:
                exit('Di');
            3:
                exit('Mi');
            4:
                exit('Do');
            5:
                exit('Fr');
            6:
                exit('Sa');
            7:
                exit('So');
        end;
    end;
}